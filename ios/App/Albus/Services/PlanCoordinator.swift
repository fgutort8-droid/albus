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

    func invalidateForAccountDeletion() {
        accountWasDeleted = true
        onScheduleChanged = nil
    }

    private let plans: PlanService
    private let scheduler = Scheduler()
    private let estimator = Estimator()

    init(plans: PlanService = PlanService()) {
        self.plans = plans
    }

    /// Adds an assignment and returns with its plan placed in time.
    ///
    /// The assignment is saved *before* the network call. If generation fails
    /// the student keeps their work and a deadline, which is the difference
    /// between a slow moment and losing what they typed.
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
               .count(where: { !$0.isComplete }),
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
            // Server-assigned id, so a later sync can match rows rather than
            // guessing by title.
            assignment.remoteID = result.assignmentID

            for (i, step) in result.steps.enumerated() {
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
            save(context, "insert steps")
            reschedule(context: context, availability: availability, now: now)
            status = .idle

        } catch let failure as PlanService.Failure where failure.plansLocally {
            guard !accountWasDeleted else { return }
            planLocally(assignment, context: context, availability: availability, now: now)
            status = .plannedLocally(note: failure.localPlanNote,
                                     suggestsUpgrade: failure.suggestsUpgrade)
        } catch let failure as PlanService.Failure {
            guard !accountWasDeleted else { return }
            // Over the open-task cap: the server refused the assignment itself,
            // so keeping it here would leave an unplanned copy nobody can act on.
            if failure == .quotaReached {
                context.delete(assignment)
                save(context, "remove refused assignment")
            }
            status = .failed(failure.errorDescription ?? "Couldn't plan that.")
        } catch {
            guard !accountWasDeleted else { return }
            planLocally(assignment, context: context, availability: availability, now: now)
            status = .plannedLocally(note: PlanService.Failure.unavailable.localPlanNote,
                                     suggestsUpgrade: false)
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
        // device the moment the student asks, and the server catches up.
        if let remoteID = assignment.remoteID {
            Task {
                if await !AssignmentService().delete(remoteID: remoteID), !accountWasDeleted {
                    PendingDeletions.record(remoteID)
                }
            }
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

        if completed {
            subtask.completedAt = now
            if let record = completionRecord(for: subtask, now: now) {
                context.insert(record)
            }
        } else {
            subtask.completedAt = nil
        }
        subtask.assignment?.updatedAt = now

        // Finishing the last step closes the assignment, which is what frees a
        // slot against the free-tier active-plan cap.
        if let assignment = subtask.assignment {
            assignment.statusValue = assignment.isComplete ? .completed : .active
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
            print("[Albus] missed-session sweep failed: \(error)")
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

        let ordinal = (assignment.subtasks.map(\.ordinal).max() ?? -1) + 1
        context.insert(Subtask(title: trimmed, ordinal: ordinal,
                               estimatedMinutes: max(5, min(600, minutes)),
                               assignment: assignment))
        assignment.updatedAt = now
        // A hand-written step can reopen a finished assignment, which is what
        // frees or consumes a slot against the free-tier cap.
        assignment.statusValue = assignment.isComplete ? .completed : .active
        save(context, "add step")
        reschedule(context: context, availability: availability, now: now)
    }

    func deleteStep(_ subtask: Subtask, context: ModelContext,
                    availability: Availability = .default,
                    now: Date = .now) {
        let assignment = subtask.assignment
        context.delete(subtask)
        assignment?.updatedAt = now
        save(context, "delete step")
        if let assignment {
            renumber(assignment)
            assignment.statusValue = assignment.isComplete ? .completed : .active
            save(context, "renumber after delete")
        }
        reschedule(context: context, availability: availability, now: now)
    }

    func moveSteps(in assignment: Assignment, from source: IndexSet, to destination: Int,
                   context: ModelContext,
                   availability: Availability = .default,
                   now: Date = .now) {
        var ordered = assignment.subtasks.sorted { $0.ordinal < $1.ordinal }
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, step) in ordered.enumerated() { step.ordinal = index }
        assignment.updatedAt = now
        save(context, "reorder steps")
        reschedule(context: context, availability: availability, now: now)
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

    private func save(_ context: ModelContext, _ what: String) {
        do { try context.save() } catch {
            // Losing a write silently is worse than a visible failure.
            status = .failed("Couldn't save.")
            print("save failed during \(what): \(error)")
        }
    }
}
