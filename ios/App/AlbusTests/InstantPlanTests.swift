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

    private func coordinator(showingSkeletonsFor limit: Duration = .seconds(8)) -> PlanCoordinator {
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
                               refiningDisplayLimit: limit)
    }

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

        func reset() {
            lock.lock(); defer { lock.unlock() }
            held = []; released = false; deleted = []
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
