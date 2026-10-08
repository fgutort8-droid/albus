import Foundation
import SwiftData
import AlbusCore

/// The core loop, in one place: an assignment goes in, a placed plan comes out.
///
///   backend breakdown  →  local persistence  →  scheduler  →  visible plan
///
/// The steps come from the server (it holds the key and enforces the quota).
/// Placing them in time is done here, on device, because a miss has to re-flow
/// instantly and offline — that is the whole product, and it cannot depend on
/// a round trip.
@Observable
@MainActor
final class PlanCoordinator {

    enum Status: Equatable {
        case idle
        case planning
        /// The AI did not plan this, so the phone did. Not a failure: the
        /// assignment has sessions and they are scheduled.
        case plannedLocally(note: String, suggestsUpgrade: Bool)
        case failed(String)
    }

    private(set) var status: Status = .idle

    /// Steps the scheduler could not fit before their deadline.
    ///
    /// The scheduler has always reported these and nothing ever read them, so a
    /// plan that does not fit looked exactly like one that does: the steps are
    /// listed, they simply never appear on any day. Twenty hours of work due
    /// tomorrow produced a full plan and a nearly empty calendar, silently.
    var unplacedStepIDs: Set<UUID> { Set(unplacedItems.map(\.id)) }
    private(set) var unplacedItems: [ScheduleItem] = []

    /// How heavy the week actually is, straight from the scheduler.
    ///
    /// The scheduler has always computed this — its own doc comment calls it
    /// "the signal the mascot's mood is derived from" — and nothing ever read
    /// it. The mascot instead used absolute minute thresholds that no study
    /// load could reach, so the cactus could never look cooked. This is that
    /// signal, finally connected to the thing named after it.
    private(set) var workload: WorkloadState = .calm

    /// How many already-placed blocks the last run moved. Low is the goal; a
    /// high number is what a student experiences as the plan being unreliable.
    private(set) var movedCount: Int = 0

    /// False when the last re-flow threw. Everything derived from a schedule —
    /// the mood, the unplaced set — is stale in that case, and anything that
    /// would tell the student about it has to hold its tongue.
    private(set) var lastRunSucceeded = true

    /// Called after every successful re-flow.
    ///
    /// A closure rather than a direct reference to the notification coordinator:
    /// this type is the core loop and has no business knowing that notifications
    /// exist, and its tests would otherwise need one.
    var onScheduleChanged: (@MainActor () -> Void)?

    private var accountWasDeleted = false

    /// Goes up each time a task the server knows finishes or opens again on
    /// this phone, so the app can tell the server, which counts open tasks.
    private(set) var statusChangesOnPhone = 0

    /// The phone could not read its own tasks, so it cannot say which are
    /// here, and nothing is sent.
    struct LocalTasksUnreadable: Error {}

    /// True while the phone is telling the server which tasks it holds and
    /// reading the plan back. The plan's count of open tasks is stale until
    /// then, so nothing should be concluded from it.
    var serverCountSettling: Bool { settlingCalls > 0 }
    private var settlingCalls = 0

    /// A sync on its way, and whether the phone changed again meanwhile.
    private var syncRunning = false
    private var syncAgain = false

    func invalidateForAccountDeletion() {
        accountWasDeleted = true
        onScheduleChanged = nil
    }

    /// Assignments whose plan the phone made and the AI is still writing, for
    /// at most `refiningDisplayLimit`. Home and the month sketch their step
    /// titles meanwhile; see `isRefining(_:)`. The task screen never does: its
    /// steps can be used from the first moment.
    private(set) var refining: Set<UUID> = []

    func isRefining(_ assignment: Assignment?) -> Bool {
        guard let assignment else { return false }
        return refining.contains(assignment.id)
    }

    /// Assignments whose AI answer has not arrived yet, however long it takes.
    private var pending: Set<UUID> = []

    /// The AI is still writing this assignment's steps and they would replace
    /// the ones shown: the student has not started using them.
    func isWritingSteps(_ assignment: Assignment?) -> Bool {
        guard let id = assignment?.id else { return false }
        return pending.contains(id) && !claimed.contains(id)
    }
    /// Pending assignments the student has started using: the AI's answer no
    /// longer replaces their steps.
    private var claimed: Set<UUID> = []

    /// The student is acting on this assignment's steps as they stand, so the
    /// AI's answer, when it comes, must not replace them.
    ///
    /// Every change made through the coordinator claims the assignment. Screens
    /// also claim before anything that holds on to a step without changing it
    /// yet, such as the step editor or a focus session being opened: replacing
    /// the step underneath would lose what the student does there. Only while
    /// the AI's answer is pending; afterwards there is nothing to replace.
    func claim(_ assignment: Assignment?) {
        guard let id = assignment?.id, pending.contains(id) else { return }
        claimed.insert(id)
        // The steps shown are the ones that stay: nothing left to sketch.
        refining.remove(id)
    }

    private let plans: PlanService
    /// Where refused assignments still in use are remembered until launch.
    private let defaults: UserDefaults
    private let assignments: AssignmentService
    /// How long step titles stay skeletons while the AI writes them. After
    /// that the phone's own titles show, and a late answer still replaces a
    /// plan nobody has touched.
    private let refiningDisplayLimit: Duration
    /// Writes changes to the phone. A seam for the test of a failed write.
    private let persist: @MainActor (ModelContext) throws -> Void
    private let scheduler = Scheduler()
    private let estimator = Estimator()

    init(plans: PlanService = PlanService(),
         assignments: AssignmentService = AssignmentService(),
         refiningDisplayLimit: Duration = .seconds(8),
         defaults: UserDefaults = .standard,
         persist: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() }) {
        self.plans = plans
        self.assignments = assignments
        self.refiningDisplayLimit = refiningDisplayLimit
        self.defaults = defaults
        self.persist = persist
    }

    /// Adds an assignment with its plan in the week at once, and returns once
    /// the AI has written the steps or declined to.
    ///
    /// The assignment is saved, and planned on the phone, *before* the network
    /// call. The student sees it in their week the moment they add it, rather
    /// than after the AI's three to fifteen seconds, and a failed generation
    /// still leaves them a working plan and everything they typed. The AI's
    /// steps then replace the phone's, unless the student has already started
    /// on them: a plan they have begun is theirs.
    func addAssignment(_ draft: NewAssignment,
                       context: ModelContext,
                       availability: Availability = .default,
                       taskLimit: Int? = nil,
                       now: Date = .now) async {
        guard !accountWasDeleted else { return }
        // The open-task cap, checked on the device first. The server trigger is
        // the authority, but it only sees assignments that reach it -- without
        // this, an offline student could plan past the cap on the phone.
        if let taskLimit,
           let open = try? context.fetch(FetchDescriptor<Assignment>())
               .count(where: { !$0.isComplete && !$0.isArchived }),
           open >= taskLimit {
            status = .failed(PlanService.Failure.quotaReached.errorDescription ?? "")
            return
        }

        status = .planning

        let assignment = Assignment(
            title: draft.title, notes: draft.notes, taskType: draft.taskType,
            deadline: draft.deadline, estimatedMinutes: draft.estimatedMinutes,
            priority: draft.priority,
            course: draft.course, rubric: draft.rubric
        )
        context.insert(assignment)
        save(context, "insert assignment")

        // The phone's plan, straight away, in the student's own week. Its step
        // titles show as skeletons until the AI's arrive, for at most
        // `refiningDisplayLimit`.
        planLocally(assignment, context: context, availability: availability, now: now)
        let localPlan = snapshot(of: assignment)
        let id = assignment.id
        pending.insert(id)
        refining.insert(id)
        let limit = refiningDisplayLimit
        let reveal = Task { [weak self] in
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            self?.refining.remove(id)
        }
        defer {
            reveal.cancel()
            refining.remove(id)
            pending.remove(id)
            claimed.remove(id)
        }

        do {
            let result = try await plans.breakdown(
                title: draft.title, taskType: draft.taskType,
                deadline: draft.deadline, estimatedMinutes: draft.estimatedMinutes,
                courseID: draft.course?.remoteID,
                notes: draft.notes,
                rubricID: draft.rubric?.id,
                priority: draft.priority,
                dailyCapacityMinutes: availability.dailyCapacityMinutes
            )

            guard !accountWasDeleted else { return }
            guard let current = existing(id, in: context) else {
                // Deleted while the AI worked. The server made the assignment
                // too, and the phone never learnt its id to delete it there.
                await deleteRemote(result.assignmentID)
                status = .idle
                return
            }
            // Server-assigned id, so a later sync can match rows rather than
            // guessing by title.
            current.remoteID = result.assignmentID

            if !result.steps.isEmpty, !claimed.contains(id), snapshot(of: current) == localPlan {
                replaceSteps(of: current, with: result.steps, context: context)
                save(context, "insert steps")
                reschedule(context: context, availability: availability, now: now)
            } else {
                // The student has started on the phone's plan, opened a step,
                // or edited it. Theirs stands.
                save(context, "link assignment")
            }
            status = .idle

        } catch let failure as PlanService.Failure where failure.plansLocally {
            guard !accountWasDeleted else { return }
            // The phone's plan is already in place.
            status = .plannedLocally(note: failure.localPlanNote,
                                     suggestsUpgrade: failure.suggestsUpgrade)
        } catch let failure as PlanService.Failure {
            guard !accountWasDeleted else { return }
            // Refused outright, over the open-task cap or as a request that
            // needs correcting: the server holds no copy and never will, so
            // the phone's copy goes too rather than sit in the week, outlasting
            // the limit that refused it.
            let refusal = failure.errorDescription ?? "Couldn't plan that."
            if failure.refusesAssignment, let current = existing(id, in: context) {
                if !claimed.contains(id), current.gradings.isEmpty, snapshot(of: current) == localPlan {
                    context.delete(current)
                    save(context, "remove refused assignment")
                    reschedule(context: context, availability: availability, now: now)
                } else {
                    // Started on already, by any route, or marked against.
                    // Removed now, it could go from under an open step or a
                    // running timer, and a marking would go with it, so the
                    // next launch takes its plan out of the week instead,
                    // before any screen can show it, and keeps the work.
                    RefusedAssignments.record(id, defaults: defaults)
                    status = .failed(refusal + " The one you just added stays until Albus next opens, as you've started on it. The work you do on it is kept.")
                    return
                }
            }
            status = .failed(refusal)
        } catch {
            guard !accountWasDeleted else { return }
            status = .plannedLocally(note: PlanService.Failure.unavailable.localPlanNote,
                                     suggestsUpgrade: false)
        }
    }

    /// What the student could have changed about a plan: which steps it has,
    /// what they say, and whether any has been started or finished.
    private struct StepSnapshot: Equatable {
        let id: UUID
        let title: String
        let minutes: Int
        let ordinal: Int
        let started: Bool
    }

    private func snapshot(of assignment: Assignment) -> [StepSnapshot] {
        assignment.subtasks
            .map { step in
                StepSnapshot(
                    id: step.id, title: step.title, minutes: step.estimatedMinutes,
                    ordinal: step.ordinal,
                    started: step.completedAt != nil || step.sessions.contains {
                        $0.startedAt != nil || ($0.focusedSeconds ?? 0) > 0
                    })
            }
            .sorted { $0.ordinal < $1.ordinal }
    }

    /// The assignment, if it is still on the phone.
    private func existing(_ id: UUID, in context: ModelContext) -> Assignment? {
        var descriptor = FetchDescriptor<Assignment>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    /// Swaps the phone's steps for the AI's. Their sessions go with them, and
    /// the re-flow that follows places the new ones.
    private func replaceSteps(of assignment: Assignment, with steps: [PlanService.Step],
                              context: ModelContext) {
        for old in Array(assignment.subtasks) { context.delete(old) }
        for (i, step) in steps.enumerated() {
            context.insert(Subtask(
                title: step.title,
                guidance: step.guidance.isEmpty ? nil : step.guidance,
                ordinal: i,
                estimatedMinutes: step.estimatedMinutes,
                criterionCode: step.criterionCode,
                toolNeed: step.toolNeed,
                assignment: assignment
            ))
        }
    }

    // MARK: - The server's count of open tasks

    /// Tells the server which of this phone's tasks are finished and which
    /// are open, then reads the plan back through `refresh`.
    ///
    /// The free plan caps open tasks on the server, but finishing a task used
    /// to change it only here, so a student who finished five was still
    /// refused a sixth. The whole picture is sent each time, not just what
    /// changed: the server changes only what differs, and a failed attempt
    /// needs no queue to be caught up by the next.
    ///
    /// One request at a time, the latest picture last. Two on the wire at once
    /// could land in either order, and an older picture applied last would
    /// undo a newer one: a task finished and reopened would end up closed on
    /// the server while open here. A change made while a request is on its way,
    /// or while the plan is being read back, is sent after it, read afresh.
    ///
    /// The open list cannot undo "Stop counting" from another phone: the
    /// server reopens only tasks it holds as finished, never ones freed
    /// (`archived`), which is how that decision survives this phone still
    /// holding them (`sync_my_assignments`, server task 08B).
    func syncServerCount(context: ModelContext, refresh: @MainActor () async -> Void) async {
        guard !accountWasDeleted else { return }
        if syncRunning {
            syncAgain = true
            return
        }
        syncRunning = true
        settlingCalls += 1
        defer {
            syncRunning = false
            settlingCalls -= 1
        }
        repeat {
            syncAgain = false
            if let finished = Self.finishedRemoteIDs(in: context), let open = Self.openRemoteIDs(in: context) {
                _ = await assignments.sync(finished: finished, open: Array(open.prefix(Self.serverListLimit)))
            }
            // The plan is read after the last request. A change made while it
            // is being read is sent next, and the plan read again.
            if !syncAgain { await refresh() }
        } while syncAgain && !accountWasDeleted
    }

    /// Stops the server counting the open tasks that are not on this phone,
    /// then reads the plan back through `refresh`. Only when the student asks:
    /// they may still use the phone those tasks are on.
    func releaseOthers(context: ModelContext, refresh: @MainActor () async -> Void) async throws {
        guard !accountWasDeleted else { return }
        // A read that failed is not an empty phone: freeing everything but
        // nothing would free the tasks that are here too.
        guard let keeping = Self.openRemoteIDs(in: context) else { throw LocalTasksUnreadable() }
        // The server takes at most 500. Past that it would free tasks that
        // are here, so it is not asked at all.
        guard keeping.count <= Self.serverListLimit else { return }
        settlingCalls += 1
        defer { settlingCalls -= 1 }
        _ = try await assignments.releaseOthers(keeping: keeping)
        await refresh()
    }

    static let serverListLimit = 500

    /// The server ids of the tasks finished on this phone, most recent first.
    /// Nil when the phone cannot read its tasks.
    static func finishedRemoteIDs(in context: ModelContext) -> [UUID]? {
        let completed = AssignmentStatus.completed.rawValue
        var descriptor = FetchDescriptor<Assignment>(
            predicate: #Predicate { $0.status == completed && $0.remoteID != nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        descriptor.fetchLimit = serverListLimit
        return (try? context.fetch(descriptor))?.compactMap(\.remoteID)
    }

    /// The server ids of the tasks open on this phone, most recent first.
    /// Nil when the phone cannot read its tasks.
    static func openRemoteIDs(in context: ModelContext) -> [UUID]? {
        let active = AssignmentStatus.active.rawValue
        let descriptor = FetchDescriptor<Assignment>(
            predicate: #Predicate { $0.status == active && $0.remoteID != nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)])
        return (try? context.fetch(descriptor))?.compactMap(\.remoteID)
    }

    /// How many open tasks the server counts that are not open on this
    /// phone, when they are what stops the student adding one here. Zero
    /// otherwise: below the cap they cost nothing, and when the phone's own
    /// tasks fill it, freeing others would not help.
    static func uncountedOnPhone(used: Int, limit: Int?, openHere: Int, openHereOnServer: Int) -> Int {
        guard let limit, limit > 0, openHere < limit, used >= limit else { return 0 }
        return max(0, used - openHereOnServer)
    }

    /// Removes a server row the phone holds no copy of, retrying later if the
    /// server cannot be reached now.
    private func deleteRemote(_ remoteID: UUID) async {
        if await !assignments.delete(remoteID: remoteID), !accountWasDeleted {
            PendingDeletions.record(remoteID)
        }
    }

    /// Sessions made on the phone, sized so every one can be placed.
    private func planLocally(_ assignment: Assignment, context: ModelContext,
                             availability: Availability, now: Date) {
        let sessions = LocalPlan.sessions(
            title: assignment.title,
            totalMinutes: assignment.estimatedMinutes,
            dailyCapacityMinutes: availability.dailyCapacityMinutes)
        for (i, session) in sessions.enumerated() {
            context.insert(Subtask(title: session.title, guidance: nil, ordinal: i,
                                   estimatedMinutes: session.minutes,
                                   criterionCode: nil, toolNeed: nil,
                                   assignment: assignment))
        }
        save(context, "insert local plan")
        reschedule(context: context, availability: availability, now: now)
    }

    /// Takes the plans the server refused while they were in use out of the
    /// week, now that no screen can be showing them. Called at launch, before
    /// anything is drawn.
    ///
    /// The plan goes; what the student did on it stays. An assignment with
    /// nothing recorded on it is deleted. One with a finished step, measured
    /// focus time or a marking is archived instead (see `archive`), so the
    /// refusal neither outlives the limit that made it nor takes their work.
    /// The list is cleared only once this is saved: a failed save is undone
    /// in memory and tried again at the next launch.
    func removeRefusedAssignments(context: ModelContext,
                                  availability: Availability = .default,
                                  now: Date = .now) {
        let refused = RefusedAssignments.all(defaults: defaults)
        guard !refused.isEmpty else { return }
        for id in refused {
            guard let assignment = existing(id, in: context) else { continue }
            if Self.hasRecordedWork(assignment) {
                archive(assignment, context: context, now: now)
            } else {
                context.delete(assignment)
            }
        }
        guard save(context, "remove refused assignments") else {
            context.rollback()
            return
        }
        RefusedAssignments.clear(defaults: defaults)
        reschedule(context: context, availability: availability, now: now)
    }

    /// Keeps the record of a refused assignment and removes its plan. Steps
    /// with nothing recorded go, and so do blocks that never ran; blocks that
    /// did run move to when they actually happened, so none is left ahead in
    /// the week. Archived, it is never scheduled, listed or counted against
    /// the open-task cap, and its markings stay in the marking history.
    private func archive(_ assignment: Assignment, context: ModelContext, now: Date) {
        for step in Array(assignment.subtasks) {
            guard Self.hasRecordedWork(step) else {
                context.delete(step)
                continue
            }
            for session in Array(step.sessions) {
                guard Self.wasRun(session) else {
                    context.delete(session)
                    continue
                }
                let began = session.startedAt ?? session.startsAt
                let ended = session.endedAt
                    ?? began.addingTimeInterval(TimeInterval(session.focusedSeconds ?? 0))
                session.startsAt = began
                session.endsAt = max(ended, began.addingTimeInterval(60))
            }
        }
        assignment.statusValue = .archived
        assignment.updatedAt = now
    }

    /// Something the student did, rather than something planned for them.
    private static func hasRecordedWork(_ assignment: Assignment) -> Bool {
        !assignment.gradings.isEmpty || assignment.subtasks.contains(where: hasRecordedWork)
    }

    private static func hasRecordedWork(_ step: Subtask) -> Bool {
        step.completedAt != nil || step.sessions.contains(where: wasRun)
    }

    /// A block a timer actually ran on, as opposed to one only planned.
    private static func wasRun(_ session: PlanSessionRecord) -> Bool {
        session.startedAt != nil || (session.focusedSeconds ?? 0) > 0
    }

    /// Removes an assignment and everything that came from it.
    ///
    /// "Delete" has to mean gone, not hidden. Locally the cascade rules take the
    /// steps, their scheduled sessions and any gradings with the assignment;
    /// server-side the same happens through `on delete cascade`. What is left
    /// after this is a schedule with the freed hours reused, which is why it
    /// re-flows rather than leaving a hole where the work used to be.
    ///
    /// The focus session is stopped first when it is running on one of these
    /// steps. Deleting the row underneath a running timer leaves it counting
    /// against a step that no longer exists, and the measurement it banks on
    /// finishing would be attached to nothing.
    ///
    /// One thing deliberately survives: `CompletionRecord`s. They carry no title
    /// and no link back to an assignment — only a task type, two durations and
    /// an hour — because they are what the on-device estimator learns from. They
    /// cannot be found by assignment, and adding a link so they could would make
    /// the learning data less anonymous than it is now, which is the wrong trade
    /// for a privacy property this app deliberately has.
    func deleteAssignment(_ assignment: Assignment,
                          context: ModelContext,
                          focusSession: FocusSession? = nil,
                          availability: Availability = .default,
                          now: Date = .now) {
        // Stop a timer running on any step of this assignment.
        if let focusSession,
           let running = focusSession.record?.subtask,
           running.assignment?.id == assignment.id {
            focusSession.cancel(context: context)
        }

        // Fire-and-forget with a retry queue behind it: the row is gone from the
        // device the moment the student asks, and the server catches up. With
        // no remote id yet, the AI is still writing the plan, and
        // `addAssignment` deletes the server's copy when its answer arrives.
        if let remoteID = assignment.remoteID {
            Task { await deleteRemote(remoteID) }
        }

        context.delete(assignment)
        save(context, "delete assignment")
        reschedule(context: context, availability: availability, now: now)
    }

    /// Marks a step done or undone and re-flows what is left.
    ///
    /// This is the other half of the core loop. Completing a step frees the
    /// time it was holding; un-completing it needs that time back. Either way
    /// the plan is rebuilt immediately and on device, so the student sees the
    /// consequence of the tap rather than a spinner.
    ///
    /// A completion also writes a `CompletionRecord` — estimate against actual
    /// — which is what the on-device estimator learns from. It carries
    /// durations and a task type, never the title, so the learning signal holds
    /// nothing about what the student is studying.
    func setCompleted(_ subtask: Subtask, _ completed: Bool,
                      context: ModelContext,
                      availability: Availability = .default,
                      now: Date = .now) {
        guard (subtask.completedAt != nil) != completed else { return }
        claim(subtask.assignment)

        if completed {
            subtask.completedAt = now
            if let record = completionRecord(for: subtask, now: now) {
                context.insert(record)
            }
        } else {
            subtask.completedAt = nil
        }
        subtask.assignment?.updatedAt = now

        // Finishing the last step closes the assignment; undoing one opens it
        // again. Either way the server hears about it (`settleStatus`).
        if let assignment = subtask.assignment {
            settleStatus(of: assignment)
        }

        save(context, "toggle step")
        reschedule(context: context, availability: availability, now: now)
    }

    /// Logs how long the step actually took — and only when that is known.
    ///
    /// This used to sum the *planned* length of the step's sessions and record
    /// it as the actual duration. That made every completion agree perfectly
    /// with its own estimate, so the estimator learned nothing and a student
    /// could bank a three-hour session with one tap.
    ///
    /// Now the only source is measured focus time from a real session. A step
    /// marked done without ever running one is still completed — plenty of work
    /// happens on paper, and refusing to believe the student would be worse —
    /// but it produces **no** duration sample rather than an invented one.
    /// Silence is a better input than a confident lie.
    private func completionRecord(for subtask: Subtask, now: Date) -> CompletionRecord? {
        let measured = subtask.sessions
            .filter { $0.sessionState != .skipped }
            .compactMap(\.measuredMinutes)
        guard !measured.isEmpty else { return nil }

        let total = measured.reduce(0, +)
        let interruptions = subtask.sessions.reduce(0) { $0 + ($1.interruptions ?? 0) }
        let assignment = subtask.assignment

        return CompletionRecord(
            subjectCode: assignment?.course?.displayName,
            taskType: assignment?.taskType ?? "other",
            estimatedMinutes: subtask.estimatedMinutes,
            actualMinutes: total,
            hourBucket: Calendar.current.component(.hour, from: now),
            // One uninterrupted sitting is a clean measurement. A session split
            // across app switches is still useful, just not evidence.
            highConfidence: measured.count == 1 && interruptions == 0,
            createdAt: now
        )
    }

    /// Marks blocks whose window has passed as missed, then re-flows the plan.
    ///
    /// This is the half of "Albus adapts to you" that nothing else does. The
    /// scheduler deliberately will not move a past block it was never told
    /// about — it cannot know whether that work happened — so something has to
    /// make the call. That is this: a block whose window has fully passed while
    /// its step is still incomplete is a miss, and a miss gets a new home.
    ///
    /// Cheap and idempotent: it only writes when something actually changed, so
    /// calling it on every appearance costs a fetch and nothing else.
    @discardableResult
    func sweepMissedSessions(context: ModelContext,
                             availability: Availability = .default,
                             now: Date = .now) -> Int {
        do {
            let sessions = try context.fetch(FetchDescriptor<PlanSessionRecord>())
            var missed = 0

            for session in sessions
            where session.sessionState == .scheduled
                && session.endsAt <= now
                && session.subtask?.completedAt == nil
                && session.subtask?.assignment?.isArchived != true
                && !session.isFixed {
                session.sessionState = .missed
                missed += 1
            }

            guard missed > 0 else { return 0 }
            save(context, "mark missed")
            reschedule(context: context, availability: availability, now: now)
            return missed
        } catch {
            // A failed sweep must not stop the screen rendering.
            print("[Albus] missed-session sweep failed")
            return 0
        }
    }

    // MARK: - Editing the plan
    //
    // Albus proposes; the student decides. A plan you cannot correct is one you
    // stop trusting the first time it is wrong about how long something takes.
    // Every edit re-flows the schedule, because changing a step's length without
    // moving what comes after it would leave the plan quietly inconsistent.

    func updateStep(_ subtask: Subtask, title: String, minutes: Int,
                    context: ModelContext,
                    availability: Availability = .default,
                    now: Date = .now) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        claim(subtask.assignment)

        let clamped = max(5, min(600, minutes))
        guard subtask.title != trimmed || subtask.estimatedMinutes != clamped else { return }

        subtask.title = trimmed
        subtask.estimatedMinutes = clamped
        subtask.assignment?.updatedAt = now
        save(context, "edit step")
        reschedule(context: context, availability: availability, now: now)
    }

    func addStep(to assignment: Assignment, title: String, minutes: Int,
                 context: ModelContext,
                 availability: Availability = .default,
                 now: Date = .now) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        claim(assignment)

        let ordinal = (assignment.subtasks.map(\.ordinal).max() ?? -1) + 1
        context.insert(Subtask(title: trimmed, ordinal: ordinal,
                               estimatedMinutes: max(5, min(600, minutes)),
                               assignment: assignment))
        assignment.updatedAt = now
        // A hand-written step can reopen a finished assignment, which is what
        // frees or consumes a slot against the free-tier cap.
        settleStatus(of: assignment)
        save(context, "add step")
        reschedule(context: context, availability: availability, now: now)
    }

    func deleteStep(_ subtask: Subtask, context: ModelContext,
                    availability: Availability = .default,
                    now: Date = .now) {
        let assignment = subtask.assignment
        claim(assignment)
        context.delete(subtask)
        assignment?.updatedAt = now
        save(context, "delete step")
        if let assignment {
            renumber(assignment)
            settleStatus(of: assignment)
            save(context, "renumber after delete")
        }
        reschedule(context: context, availability: availability, now: now)
    }

    func moveSteps(in assignment: Assignment, from source: IndexSet, to destination: Int,
                   context: ModelContext,
                   availability: Availability = .default,
                   now: Date = .now) {
        claim(assignment)
        var ordered = assignment.subtasks.sorted { $0.ordinal < $1.ordinal }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, step) in ordered.enumerated() { step.ordinal = index }
        assignment.updatedAt = now
        save(context, "reorder steps")
        reschedule(context: context, availability: availability, now: now)
    }

    /// Completed once every step is done, active otherwise. Archived stays
    /// archived: it is a record of work now, and a change to it must not turn
    /// it back into a plan.
    /// Every path that can finish a task, or open a finished one again,
    /// comes through here: ticking a step, undoing one, adding a step, or
    /// deleting the one that was still open. The open-task cap is counted
    /// on the server, so each change is reported (`syncServerCount`).
    private func settleStatus(of assignment: Assignment) {
        guard !assignment.isArchived else { return }
        let settled: AssignmentStatus = assignment.isComplete ? .completed : .active
        guard assignment.statusValue != settled else { return }
        assignment.statusValue = settled
        if assignment.remoteID != nil { statusChangesOnPhone += 1 }
    }

    /// Ordinals must stay contiguous: the scheduler places work in ordinal
    /// order, and a gap is harmless while a duplicate is not.
    private func renumber(_ assignment: Assignment) {
        for (index, step) in assignment.subtasks.sorted(by: { $0.ordinal < $1.ordinal }).enumerated() {
            step.ordinal = index
        }
    }

    /// The session to open Focus Mode with for this step.
    ///
    /// Prefers the block the scheduler already placed — that is the plan, and
    /// starting it keeps measured time attached to the slot it was meant for. If
    /// there is none (the student got to it early, or the step was added by
    /// hand), one is created starting now. Returning nil would mean a button
    /// that sometimes silently does nothing.
    func session(toStart subtask: Subtask, context: ModelContext,
                 now: Date = .now) -> PlanSessionRecord? {
        claim(subtask.assignment)
        let candidates = subtask.sessions
            .filter { $0.sessionState == .scheduled || $0.sessionState == .missed }
            .sorted { $0.startsAt < $1.startsAt }

        if let planned = candidates.first(where: { $0.endsAt > now }) ?? candidates.first {
            return planned
        }

        let minutes = max(5, min(600, subtask.estimatedMinutes))
        let record = PlanSessionRecord(
            startsAt: now,
            endsAt: now.addingTimeInterval(TimeInterval(minutes * 60)),
            subtask: subtask
        )
        context.insert(record)
        save(context, "create ad-hoc session")
        return record
    }

    /// Re-places everything that still needs time.
    ///
    /// Safe to call on any change — the scheduler pins history and moves as
    /// little as possible, so this is not a teardown.
    func reschedule(context: ModelContext,
                    availability: Availability = .default,
                    now: Date = .now) {
        do {
            let assignments = try context.fetch(FetchDescriptor<Assignment>())
            let existing = try context.fetch(FetchDescriptor<PlanSessionRecord>())
            let subtasks = try context.fetch(FetchDescriptor<Subtask>())

            let result = scheduler.schedule(
                items: PlanBridge.scheduleItems(from: assignments,
                                                estimator: estimator,
                                                logs: completionLogs(context, now: now),
                                                now: now),
                existing: PlanBridge.plannedSessions(from: existing),
                commitments: PlanBridge.commitments(from: existing),
                availability: availability,
                now: now
            )

            PlanBridge.apply(
                result, to: context,
                subtasksByID: Dictionary(subtasks.map { ($0.id, $0) },
                                         uniquingKeysWith: { a, _ in a }),
                existing: existing
            )
            unplacedItems = result.unplaceable
            workload = result.workload
            movedCount = result.movedCount
            lastRunSucceeded = true
            save(context, "apply schedule")
            // Every mutation path — add, delete, complete, the missed sweep and
            // all four plan edits — ends here, so this is the only hook the
            // notification rebuild needs. Debounced, because reordering steps
            // calls this several times in a row.
            onScheduleChanged?()
        } catch {
            // Everything derived above keeps its previous value, which is now
            // describing a plan that was not rebuilt. Anything acting on it —
            // the mascot's mood, a "your plan stopped fitting" alert — has to
            // know that, or it reports a state the student cannot see or fix.
            lastRunSucceeded = false
            status = .failed("Couldn't rebuild your plan.")
        }
    }

    /// What the estimator learns from, bounded to what can still matter.
    ///
    /// Weight half-lives every 30 days, so a log from six months ago carries
    /// about 1.5% of a fresh one — indistinguishable from zero once shrunk
    /// toward the prior. Fetching the full history on every re-flow would grow
    /// without limit for a signal that stopped moving the answer long ago.
    private func completionLogs(_ context: ModelContext, now: Date) -> [CompletionLog] {
        let cutoff = now.addingTimeInterval(-180 * 86_400)
        let descriptor = FetchDescriptor<CompletionRecord>(
            predicate: #Predicate { $0.createdAt > cutoff }
        )
        guard let records = try? context.fetch(descriptor) else { return [] }
        return PlanBridge.completionLogs(from: records)
    }

    @discardableResult
    private func save(_ context: ModelContext, _ what: StaticString) -> Bool {
        do {
            try persist(context)
            return true
        } catch {
            // Losing a write silently is worse than a visible failure.
            status = .failed("Couldn't save.")
            print("save failed during \(what)")
            return false
        }
    }
}

/// Assignments the server refused after the student had started on them,
/// kept until the next launch removes them. Refused ones never reach the
/// server, so there is nothing to delete there.
enum RefusedAssignments {
    private static let key = "albus.refusedAssignments"

    static func record(_ id: UUID, defaults: UserDefaults = .standard) {
        var ids = all(defaults: defaults)
        guard !ids.contains(id) else { return }
        ids.append(id)
        defaults.set(ids.map(\.uuidString), forKey: key)
    }

    static func all(defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}
