import Foundation
import SwiftUI
import UIKit
import Supabase
import SwiftData
import Testing
import AlbusCore
@testable import Albus

/// A new assignment is in the week the moment it is added: the phone plans it
/// at once, and the AI's steps replace that plan when they arrive, unless the
/// student has already started on it. The AI here is a stand-in that holds its
/// answer until the test releases it, so each moment in between can be checked.
@MainActor
@Suite("An assignment's plan appears at once", .serialized)
struct InstantPlanTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let availability = Availability(windowStartHour: 0, windowEndHour: 24,
                                            dailyCapacityMinutes: 60)
    private static let serverID = UUID(uuidString: "5e5e0000-0000-4000-8000-000000000042")!

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)))
    }

    private func essay() -> NewAssignment {
        NewAssignment(title: "History essay", taskType: "essay",
                      deadline: now.addingTimeInterval(14 * 86_400),
                      estimatedMinutes: 240)
    }

    private func coordinator(showingSkeletonsFor limit: Duration = .seconds(8),
                             saves: SaveSwitch = SaveSwitch()) -> PlanCoordinator {
        HeldPlanTransport.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldPlanTransport.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!,
                                           keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://instant-plan-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return PlanCoordinator(plans: PlanService(client: client),
                               assignments: AssignmentService(client: client),
                               refiningDisplayLimit: limit,
                               defaults: refusedList,
                               persist: { context in
                                   if saves.fail { throw SaveSwitch.Failure() }
                                   try context.save()
                               })
    }

    /// Where refused assignments in use wait for launch: this test's own.
    private let refusedList = UserDefaults(suiteName: "albus.tests.refused.\(UUID().uuidString)")!

    private func eventually(within limit: Duration = .seconds(3),
                            _ condition: () throws -> Bool) async rethrows -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        while try !condition() {
            if clock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func assignment(in context: ModelContext) throws -> Assignment? {
        try context.fetch(FetchDescriptor<Assignment>()).first
    }

    private func titles(_ assignment: Assignment) -> [String] {
        assignment.subtasks.sorted { $0.ordinal < $1.ordinal }.map(\.title)
    }

    @Test("the plan is in the week before the AI answers, and the AI's steps then replace it")
    func instantThenRefined() async throws {
        let context = try store()
        let coordinator = coordinator()
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }

        // Before the AI has answered: a placed plan, with its titles pending.
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        #expect(coordinator.isRefining(added))
        #expect(coordinator.status == .planning)
        #expect(!(try context.fetch(FetchDescriptor<PlanSessionRecord>())).isEmpty,
                "the phone's sessions are on the calendar already")
        #expect(added.remoteID == nil)

        HeldPlanTransport.state.release()
        await adding.value

        #expect(titles(added) == HeldPlanTransport.aiTitles)
        #expect(added.remoteID == Self.serverID)
        #expect(!coordinator.isRefining(added))
        #expect(coordinator.status == .idle)
        let sessions = try context.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(!sessions.isEmpty)
        #expect(sessions.allSatisfy { HeldPlanTransport.aiTitles.contains($0.subtask?.title ?? "") },
                "the phone's sessions went with its steps")
    }

    @Test("a plan the student has started is kept when the AI answers")
    func startedPlanIsKept() async throws {
        let context = try store()
        let coordinator = coordinator()
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        let first = try #require(added.subtasks.min { $0.ordinal < $1.ordinal })
        coordinator.setCompleted(first, true, context: context, availability: availability, now: now)
        let theirs = titles(added)

        HeldPlanTransport.state.release()
        await adding.value

        #expect(titles(added) == theirs)
        #expect(first.completedAt != nil)
        #expect(added.remoteID == Self.serverID, "still linked to the server's copy")
    }

    @Test("an assignment deleted while the AI writes it is deleted on the server too")
    func deletedWhileRefining() async throws {
        let context = try store()
        let coordinator = coordinator()
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        coordinator.deleteAssignment(added, context: context, availability: availability, now: now)
        #expect(try assignment(in: context) == nil)

        HeldPlanTransport.state.release()
        await adding.value

        #expect(try assignment(in: context) == nil, "not brought back by the answer")
        #expect(HeldPlanTransport.state.deletions.map { $0.lowercased() }
                == ["id=eq.\(Self.serverID.uuidString.lowercased())"])
        #expect(!PendingDeletions.all().contains(Self.serverID))
    }

    @Test("the skeleton gives way after its limit, and a late answer still replaces an untouched plan")
    func skeletonHasALimit() async throws {
        let context = try store()
        let coordinator = coordinator(showingSkeletonsFor: .milliseconds(200))
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        #expect(coordinator.isRefining(added))
        #expect(await eventually(within: .seconds(2)) { !coordinator.isRefining(added) },
                "the phone's titles show once the limit passes")
        #expect(added.remoteID == nil, "the AI has still not answered")

        HeldPlanTransport.state.release()
        await adding.value
        #expect(titles(added) == HeldPlanTransport.aiTitles)
    }

    /// The reported bug: the step editor was open when the answer came, the
    /// answer replaced the step, and the student's save went nowhere.
    @Test("a step open in the editor is never replaced under it")
    func openStepSurvivesLateAnswer() async throws {
        let context = try store()
        let coordinator = coordinator(showingSkeletonsFor: .milliseconds(100))
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        #expect(await eventually { !coordinator.isRefining(added) }, "the phone's titles are showing")
        #expect(coordinator.isWritingSteps(added))
        let theirs = titles(added)
        let open = try #require(added.subtasks.min { $0.ordinal < $1.ordinal })

        coordinator.claim(added)  // what opening the editor does
        #expect(!coordinator.isWritingSteps(added))
        HeldPlanTransport.state.release()
        await adding.value

        #expect(titles(added) == theirs, "the answer came while the step was open")
        coordinator.updateStep(open, title: "My own first step", minutes: 45, context: context,
                               availability: availability, now: now)
        #expect(added.subtasks.contains { $0.id == open.id && $0.title == "My own first step" },
                "and the save lands on the step the editor was opened on")
        #expect(added.remoteID == Self.serverID, "still linked to the server's copy")
    }

    @Test("using the steps in any way keeps them, and clears the sketches at once",
          arguments: ["open", "done", "rename", "add", "remove", "reorder", "start"])
    func anyUseKeepsThePlan(action: String) async throws {
        let context = try store()
        let coordinator = coordinator()
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        #expect(coordinator.isRefining(added))
        let ordered = added.subtasks.sorted { $0.ordinal < $1.ordinal }
        let first = try #require(ordered.first)
        var session: PlanSessionRecord?
        switch action {
        case "open": coordinator.claim(added)
        case "done": coordinator.setCompleted(first, true, context: context, availability: availability, now: now)
        case "rename": coordinator.updateStep(first, title: "Mine", minutes: 30, context: context,
                                              availability: availability, now: now)
        case "add": coordinator.addStep(to: added, title: "Extra", minutes: 30, context: context,
                                        availability: availability, now: now)
        case "remove": coordinator.deleteStep(first, context: context, availability: availability, now: now)
        case "reorder": coordinator.moveSteps(in: added, from: IndexSet(integer: 0), to: 2, context: context,
                                              availability: availability, now: now)
        default: session = coordinator.session(toStart: first, context: context, now: now)
        }
        #expect(!coordinator.isRefining(added), "the titles shown are the ones that stay")
        #expect(!coordinator.isWritingSteps(added))
        let theirs = titles(added)

        HeldPlanTransport.state.release()
        await adding.value
        #expect(titles(added) == theirs)
        if let session {
            #expect(first.sessions.contains { $0.id == session.id },
                    "the session opening in the timer is still there")
        }
    }

    /// Refused at the request boundary: the real `PlanService` reads the
    /// server's answer, as it does in the app.
    @Test("an assignment the server refuses leaves the week",
          arguments: [(422, "REFUSED", "The assignment could not be planned."),
                      (422, "INVALID_DEADLINE", "Deadline must be an ISO-8601 timestamp."),
                      (413, "PAYLOAD_TOO_LARGE", "Too large."),
                      (402, "PLAN_TASK_LIMIT_REACHED", "Limit.")])
    func refusedAssignmentLeaves(status: Int, error: String, message: String) async throws {
        let context = try store()
        let coordinator = coordinator()
        HeldPlanTransport.state.refuse(status: status, error: error, message: message)
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false },
                "in the week while the server considers it")

        HeldPlanTransport.state.release()
        await adding.value

        #expect(try assignment(in: context) == nil, "no copy the server will never accept")
        #expect(try context.fetch(FetchDescriptor<Subtask>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlanSessionRecord>()).isEmpty, "nothing left on the calendar")
        guard case .failed(let why) = coordinator.status else {
            Issue.record("expected the refusal to be shown, got \(coordinator.status)")
            return
        }
        #expect(!why.isEmpty)
        if error == "REFUSED" { #expect(why == message, "the server's reason, in its words") }
    }

    /// Refused while in use: it stays while it might be on screen, and the
    /// next launch removes it, so the limit that refused it is not outlived.
    @Test("a refused assignment the student has started on stays until the next launch, then goes")
    func refusedButInUseStays() async throws {
        let context = try store()
        let coordinator = coordinator()
        HeldPlanTransport.state.refuse(status: 422, error: "REFUSED", message: "The assignment could not be planned.")
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        let first = try #require(added.subtasks.min { $0.ordinal < $1.ordinal })
        let timer = try #require(coordinator.session(toStart: first, context: context, now: now))
        let theirs = titles(added)

        HeldPlanTransport.state.release()
        await adding.value

        #expect(try assignment(in: context)?.id == added.id, "not taken from under the timer")
        #expect(titles(added) == theirs)
        #expect(first.sessions.contains { $0.id == timer.id })
        guard case .failed(let why) = coordinator.status else {
            Issue.record("the refusal is still shown, got \(coordinator.status)")
            return
        }
        #expect(why.contains("stays until Albus next opens"))

        // The next launch, before anything is drawn.
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: now)
        #expect(try assignment(in: context) == nil, "not a plan the limit never counts")
        #expect(try context.fetch(FetchDescriptor<PlanSessionRecord>()).isEmpty)
        #expect(RefusedAssignments.all(defaults: refusedList).isEmpty)
    }

    /// A timer can start without passing through the coordinator; what it
    /// changes is enough on its own to keep the plan, and, being work, it
    /// outlasts the plan at the next launch.
    @Test("a refused assignment whose session has begun by any route stays until the next launch")
    func refusedAfterAnyStartStays() async throws {
        let context = try store()
        let coordinator = coordinator()
        HeldPlanTransport.state.refuse(status: 402, error: "PLAN_TASK_LIMIT_REACHED", message: "Limit.")
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        let session = try #require(added.subtasks.flatMap(\.sessions).first)
        session.startedAt = now  // what `FocusSession.start` does

        HeldPlanTransport.state.release()
        await adding.value
        #expect(try assignment(in: context)?.id == added.id)
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: now)
        let kept = try #require(try assignment(in: context), "begun, it is kept as a record")
        #expect(kept.isArchived, "and is no longer a plan")
        #expect(kept.subtasks.flatMap(\.sessions).map(\.id) == [session.id], "the plan around it goes")
    }

    /// The plan goes at the next launch; what the student did on it does not.
    @Test("work done on a refused assignment is kept when its plan goes",
          arguments: ["focus", "finish", "mark"])
    func refusedWorkIsKept(work: String) async throws {
        let context = try store()
        let coordinator = coordinator()
        HeldPlanTransport.state.refuse(status: 402, error: "PLAN_TASK_LIMIT_REACHED", message: "Limit.")
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        let ordered = added.subtasks.sorted { $0.ordinal < $1.ordinal }
        #expect(ordered.count > 1, "steps with nothing on them, to be removed")
        let first = try #require(ordered.first)
        let run = try #require(first.sessions.first)
        switch work {
        case "focus":
            // What `FocusSession` leaves when a timer is stopped part-way.
            run.startedAt = now
            run.endedAt = now.addingTimeInterval(1_200)
            run.focusedSeconds = 1_200
            run.sessionState = .scheduled
        case "finish":
            coordinator.setCompleted(first, true, context: context,
                                     availability: availability, now: now)
        default:
            context.insert(Grading(model: "test", inputChars: 600,
                                   feedback: "A clear argument.", assignment: added))
        }
        try context.save()

        HeldPlanTransport.state.release()
        await adding.value
        #expect(RefusedAssignments.all(defaults: refusedList) == [added.id])

        let later = now.addingTimeInterval(3_600)
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: later)
        let kept = try #require(try assignment(in: context), "the work keeps its assignment")
        #expect(kept.isArchived)
        #expect(RefusedAssignments.all(defaults: refusedList).isEmpty)
        let sessions = try context.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(sessions.allSatisfy { $0.endsAt <= later }, "nothing of it is left ahead in the week")
        #expect(PlanBridge.notificationBlocks(from: sessions).isEmpty, "nothing reminds the student about it")
        switch work {
        case "focus":
            #expect(kept.subtasks.map(\.id) == [first.id], "steps with nothing recorded go")
            #expect(sessions.map(\.id) == [run.id], "blocks that never ran go")
            #expect(run.focusedSeconds == 1_200)
            #expect(run.startsAt == now && run.endsAt == now.addingTimeInterval(1_200),
                    "the block that ran sits where it happened")
        case "finish":
            #expect(kept.subtasks.map(\.id) == [first.id], "steps with nothing recorded go")
            #expect(first.completedAt != nil)
        default:
            #expect(kept.gradings.count == 1, "the marking is kept")
            #expect(kept.subtasks.isEmpty, "every step was plan")
        }

        // A record from now on: a re-plan, a change or a sweep leaves it as it is.
        coordinator.reschedule(context: context, availability: availability, now: later)
        coordinator.sweepMissedSessions(context: context, availability: availability,
                                        now: later.addingTimeInterval(86_400))
        if let step = kept.subtasks.first {
            coordinator.setCompleted(step, step.completedAt == nil, context: context,
                                     availability: availability, now: later)
        }
        #expect(kept.isArchived, "nothing turns it back into a plan")
        if work == "focus" {
            #expect(try context.fetch(FetchDescriptor<PlanSessionRecord>()).map(\.id) == [run.id],
                    "recorded focus survives every re-plan")
            #expect(run.startsAt == now && run.endsAt == now.addingTimeInterval(1_200),
                    "and is never moved")
            #expect(run.sessionState == .scheduled, "or relabelled as missed")
        }
    }

    @Test("an archived assignment does not count against the open-task cap")
    func archivedIsNotCounted() async throws {
        let context = try store()
        let coordinator = coordinator()
        context.insert(Assignment(title: "Refused essay", deadline: now, estimatedMinutes: 60,
                                  status: .archived))
        try context.save()
        HeldPlanTransport.state.release()
        await coordinator.addAssignment(essay(), context: context, availability: availability,
                                        taskLimit: 1, now: now)
        #expect(try context.fetch(FetchDescriptor<Assignment>()).count == 2)
        #expect(coordinator.status == .idle)
    }

    @Test("a launch whose removal fails to save keeps it listed, and the next launch removes it")
    func failedRemovalIsRetried() async throws {
        let context = try store()
        let saves = SaveSwitch()
        let coordinator = coordinator(saves: saves)
        HeldPlanTransport.state.refuse(status: 422, error: "REFUSED",
                                       message: "The assignment could not be planned.")
        let adding = Task {
            await coordinator.addAssignment(essay(), context: context,
                                            availability: availability, now: now)
        }
        #expect(try await eventually { try assignment(in: context)?.subtasks.isEmpty == false })
        let added = try #require(try assignment(in: context))
        coordinator.claim(added)  // opened, with nothing recorded: deleted at launch
        HeldPlanTransport.state.release()
        await adding.value
        #expect(try assignment(in: context)?.id == added.id)

        saves.fail = true
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: now)
        #expect(RefusedAssignments.all(defaults: refusedList) == [added.id], "still listed for the next launch")
        #expect(try assignment(in: context)?.id == added.id, "nothing half-removed in memory")
        #expect(coordinator.status == .failed("Couldn't save."))

        saves.fail = false
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: now)
        #expect(try assignment(in: context) == nil)
        #expect(RefusedAssignments.all(defaults: refusedList).isEmpty)
    }

    @Test("a launch with nothing refused changes nothing")
    func launchWithNothingRefused() async throws {
        let context = try store()
        let coordinator = coordinator()
        HeldPlanTransport.state.release()
        await coordinator.addAssignment(essay(), context: context, availability: availability, now: now)
        let added = try #require(try assignment(in: context))
        coordinator.removeRefusedAssignments(context: context, availability: availability, now: now)
        #expect(try assignment(in: context)?.id == added.id)
    }

    @Test("when the AI cannot plan, the phone's plan stays, with nothing pending")
    func failedAIKeepsThePhonesPlan() async throws {
        let context = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: nil))
        await coordinator.addAssignment(essay(), context: context,
                                        availability: availability, now: now)
        let added = try #require(try assignment(in: context))
        #expect(added.subtasks.count == 4)
        #expect(!coordinator.isRefining(added))
        if case .plannedLocally = coordinator.status {} else {
            Issue.record("expected the phone's plan, got \(coordinator.status)")
        }
    }
}

/// Makes the coordinator's writes fail on demand, as a full disk would.
@MainActor
private final class SaveSwitch {
    struct Failure: Error {}
    var fail = false
}

/// The server, for these tests only: `breakdown` answers when released, and
/// assignment deletions are recorded. Nothing reaches a real server.
private final class HeldPlanTransport: URLProtocol, @unchecked Sendable {
    /// Sized to fit the tests' 60-minute study day, as the real planner is told to.
    static let aiTitles = ["Gather three sources", "Outline the argument", "Draft the essay"]

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var held: [HeldPlanTransport] = []
        private var released = false
        private var deleted: [String] = []
        private var refusal: (status: Int, body: Data)?

        func reset() {
            lock.lock(); defer { lock.unlock() }
            held = []; released = false; deleted = []; refusal = nil
        }
        /// Answer `breakdown` with this refusal instead of a plan.
        func refuse(status: Int, error: String, message: String) {
            lock.lock(); defer { lock.unlock() }
            refusal = (status, try! JSONSerialization.data(withJSONObject: ["error": error, "message": message]))
        }
        var refusalToSend: (status: Int, body: Data)? {
            lock.lock(); defer { lock.unlock() }
            return refusal
        }
        /// False once released: later requests are answered straight away.
        func hold(_ request: HeldPlanTransport) -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard !released else { return false }
            held.append(request)
            return true
        }
        func release() {
            lock.lock()
            released = true
            let waiting = held
            held = []
            lock.unlock()
            waiting.forEach { $0.answerOnLoadingThread() }
        }
        func recordDeletion(_ query: String) {
            lock.lock(); defer { lock.unlock() }
            deleted.append(query)
        }
        var deletions: [String] {
            lock.lock(); defer { lock.unlock() }
            return deleted
        }
    }
    static let state = State()

    private var runLoop: CFRunLoop?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        runLoop = CFRunLoopGetCurrent()
        let url = request.url!
        if request.httpMethod == "DELETE", url.path.hasSuffix("/rest/v1/assignments") {
            Self.state.recordDeletion(url.query ?? "")
            respond(status: 204, body: Data())
        } else if url.path.hasSuffix("/functions/v1/breakdown") {
            if !Self.state.hold(self) { answer() }
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    fileprivate func answerOnLoadingThread() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in answer() }
        CFRunLoopWakeUp(runLoop)
    }

    private func answer() {
        if let refusal = Self.state.refusalToSend {
            respond(status: refusal.status, body: refusal.body)
            return
        }
        let steps = Self.aiTitles.map { title in
            ["title": title, "guidance": "", "estimated_minutes": 60,
             "rubric_criterion_code": NSNull(), "tool_need": NSNull()] as [String: Any]
        }
        let body: [String: Any] = [
            "assignment_id": "5e5e0000-0000-4000-8000-000000000042",
            "model": "claude-haiku-4-5", "rubric_grounded": false,
            "rubric_source": NSNull(), "steps": steps,
        ]
        respond(status: 200, body: try! JSONSerialization.data(withJSONObject: body))
    }

    private func respond(status: Int, body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Home and the task screen in the seconds between adding an assignment and
/// the AI's answer, drawn to PNG files for a person to look at. Off unless
/// asked for, like the other snapshot suites.
@MainActor
@Suite("Instant plan snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"] != nil))
struct InstantPlanSnapshots {

    private actor FixedPlan: PlanReading {
        func fetch() async throws -> EntitlementService.Plan? { .freeFallback }
    }

    private func render(_ name: String, _ view: some View) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1.2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    @Test func whileTheAIWrites() async throws {
        HeldPlanTransport.state.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldPlanTransport.self]
        let defaults = UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
        let storage = ResilientAuthStorage(fallback: defaults, keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://instant-plan-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        let coordinator = PlanCoordinator(plans: PlanService(client: client),
                                          assignments: AssignmentService(client: client))
        let container = try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let entitlements = EntitlementService(reader: FixedPlan())
        await entitlements.refresh()
        let preferences = Preferences()

        let adding = Task {
            await coordinator.addAssignment(
                NewAssignment(title: "History essay", taskType: "essay",
                              deadline: .now.addingTimeInterval(10 * 86_400), estimatedMinutes: 240),
                context: context, availability: preferences.availability)
        }
        defer { HeldPlanTransport.state.release() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while (try context.fetch(FetchDescriptor<Assignment>()).first?.subtasks.isEmpty ?? true),
              clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let assignment = try #require(try context.fetch(FetchDescriptor<Assignment>()).first)
        #expect(coordinator.isRefining(assignment))

        func dressed(_ view: some View) -> some View {
            view
                .environment(coordinator)
                .environment(preferences)
                .environment(entitlements)
                .environment(FocusSession())
                .environment(SessionService(client: nil, storage: storage))
                .environment(NotificationRouter())
                .modelContainer(container)
        }
        try await render("1-home-while-ai-writes",
                         dressed(NavigationStack { Screen { HomeScreen() } }))
        try await render("2-task-while-ai-writes",
                         dressed(NavigationStack { Screen { TaskDetailScreen(assignment: assignment) } }))

        HeldPlanTransport.state.release()
        await adding.value
        try await render("3-task-after-ai",
                         dressed(NavigationStack { Screen { TaskDetailScreen(assignment: assignment) } }))
    }
}
