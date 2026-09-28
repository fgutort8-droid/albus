import Foundation
import SwiftUI
import UIKit
import Supabase
import SwiftData
import Testing
@testable import Albus

/// Marking that carries on without its screen: it is stored and announced
/// wherever the student is, and an answer lost on the way back is found on the
/// server rather than reported as a failure, without the work being sent twice.
@MainActor
@Suite("Marking you can leave", .serialized)
struct MarkingCoordinatorTests {

    private static let markedID = UUID(uuidString: "6a6a0000-0000-4000-8000-000000000001")!
    private static let savedID = UUID(uuidString: "6a6a0000-0000-4000-8000-000000000002")!
    private static let olderID = UUID(uuidString: "6a6a0000-0000-4000-8000-000000000003")!
    private let work = String(repeating: "The treaty changed the balance of power in Europe. ", count: 6)

    @MainActor
    private final class RecordingAnnouncer: MarkingAnnouncer {
        var isAppActive = true
        var notified: [(UUID, String?)] = []
        func notifyMarkingReady(gradingID: UUID, title: String?) { notified.append((gradingID, title)) }
    }

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)))
    }

    private func coordinator(_ announcer: RecordingAnnouncer,
                             recoveryWindow: TimeInterval = 5) -> MarkingCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MarkingServer.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!,
                                           keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://marking-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return MarkingCoordinator(service: GradingService(client: client), announcer: announcer,
                                  recoveryWindow: recoveryWindow, pollInterval: .milliseconds(40))
    }

    private func mark(_ coordinator: MarkingCoordinator, context: ModelContext,
                      mayStore: Bool = true) async -> MarkingCoordinator.Outcome {
        await coordinator.mark(work: work, rubricID: nil, assignment: nil, presentation: nil,
                               title: "History essay", isBlind: false, context: context,
                               mayStore: { mayStore })
    }

    private func stored(_ context: ModelContext) throws -> [Grading] {
        try context.fetch(FetchDescriptor<Grading>())
    }

    @Test("a marking nobody is watching raises the ready banner, and is stored")
    func bannerWhenNotWatching() async throws {
        MarkingServer.state.reset(grade: .answer)
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.remoteID == Self.markedID)
        #expect(grading.workTitle == "History essay")
        #expect(coordinator.ready == grading.id)
        #expect(announcer.notified.isEmpty, "the app is on screen: the banner speaks")
        #expect(coordinator.current == nil)
    }

    @Test("a marking that finishes while Albus is in the background sends a notification")
    func notificationInBackground() async throws {
        MarkingServer.state.reset(grade: .answer)
        let context = try store(), announcer = RecordingAnnouncer()
        announcer.isAppActive = false
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(announcer.notified.map(\.0) == [grading.id])
        #expect(announcer.notified.first?.1 == "History essay")
        #expect(coordinator.ready == grading.id, "and the banner waits for their return")
    }

    @Test("a marking the grader screen is showing raises no banner")
    func watchedMarkingHasNoBanner() async throws {
        MarkingServer.state.reset(grade: .answer)
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer)
        coordinator.isWatched = true

        _ = await mark(coordinator, context: context)

        #expect(coordinator.ready == nil)
        #expect(announcer.notified.isEmpty)
    }

    @Test("a lost answer is found on the server, and the work is sent once")
    func lostAnswerIsRecovered() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[], [Self.savedID]])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.remoteID == Self.savedID)
        #expect(MarkingServer.state.gradeRequests == 1, "never a second, paid marking")
        #expect(MarkingServer.state.lookups == 2)
        #expect(coordinator.ready == grading.id)
    }

    @Test("a lost answer with nothing saved fails after the window, still sent once")
    func lostAnswerWithNothingSavedFails() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[]])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer, recoveryWindow: 0.3)

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .failed(.unavailable))
        #expect(try stored(context).isEmpty)
        #expect(MarkingServer.state.gradeRequests == 1)
        #expect(MarkingServer.state.lookups > 1, "it kept looking until the window closed")
        #expect(coordinator.ready == nil)
    }

    @Test("with no connection at all, the answer is offline and nothing is looked up")
    func noConnectionIsOffline() async throws {
        MarkingServer.state.reset(grade: .noConnection)
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .failed(.offline))
        #expect(MarkingServer.state.lookups == 0)
    }

    @Test("an account deleted during the marking stores and announces nothing")
    func deletedAccountStoresNothing() async throws {
        MarkingServer.state.reset(grade: .answer)
        let context = try store(), announcer = RecordingAnnouncer()
        announcer.isAppActive = false
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context, mayStore: false)

        #expect(outcome == .discarded)
        #expect(try stored(context).isEmpty)
        #expect(coordinator.ready == nil)
        #expect(announcer.notified.isEmpty)
    }

    @Test("recovery skips a grading already on the phone and waits for the new one")
    func recoverySkipsAnEarlierGrading() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[Self.olderID], [Self.savedID]])
        let context = try store(), announcer = RecordingAnnouncer()
        context.insert(Grading(remoteID: Self.olderID, model: "claude-opus-5", inputChars: 300,
                               overallMarks: nil, totalMarks: nil, gradeLabel: nil, gradeNote: nil,
                               workTitle: "Earlier essay", criteria: [], feedback: "Earlier.",
                               improvements: [], basis: .blind, assignment: nil))
        try context.save()
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        let new = try #require(try stored(context).first { $0.remoteID == Self.savedID })
        #expect(outcome == .marked(new.id))
        #expect(try stored(context).count == 2, "the earlier grading is not stored twice")
    }

    @Test("a student back after the window still gets one look, and their marking")
    func lateReturnStillLooksOnce() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[Self.savedID]])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer, recoveryWindow: 0)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(MarkingServer.state.lookups == 1)
    }
}

/// The server, for these tests only. `grade` answers, loses its answer or has
/// no connection; each read of `gradings` returns the next saved set. Nothing
/// reaches a real server.
private final class MarkingServer: URLProtocol, @unchecked Sendable {
    enum Grade { case answer, loseAnswer, noConnection, hold }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var grade: Grade = .answer
        private var saved: [[UUID]] = [[]]
        private var grades = 0
        private var reads = 0
        private var held: [MarkingServer] = []

        func reset(grade: Grade, saved: [[UUID]] = [[]]) {
            lock.lock(); defer { lock.unlock() }
            self.grade = grade; self.saved = saved; grades = 0; reads = 0; held = []
        }
        func hold(_ request: MarkingServer) {
            lock.lock(); defer { lock.unlock() }
            held.append(request)
        }
        /// Ends every held marking as if the connection had been refused.
        func releaseHeld() {
            lock.lock()
            let waiting = held
            held = []
            lock.unlock()
            waiting.forEach { $0.failOnLoadingThread() }
        }
        func nextGrade() -> Grade {
            lock.lock(); defer { lock.unlock() }
            grades += 1
            return grade
        }
        /// The last set repeats once the list runs out.
        func nextSaved() -> [UUID] {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            return saved[min(reads - 1, saved.count - 1)]
        }
        var gradeRequests: Int { lock.lock(); defer { lock.unlock() }; return grades }
        var lookups: Int { lock.lock(); defer { lock.unlock() }; return reads }
    }
    static let state = State()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private var runLoop: CFRunLoop?

    fileprivate func failOnLoadingThread() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        CFRunLoopWakeUp(runLoop)
    }

    private static var criteria: [[String: Any]] {
        [["code": "A", "name": "Argument", "marks": 3, "out_of": 4,
          "comment": "Clear line of argument.", "quote": NSNull(), "where": NSNull()]]
    }
    private static var improvements: [[String: Any]] { [["change": "Cite more.", "why": "Evidence."]] }

    override func startLoading() {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/functions/v1/grade") {
            switch Self.state.nextGrade() {
            case .answer:
                respond([
                    "id": "6a6a0000-0000-4000-8000-000000000001", "overall_marks": 6, "total_marks": 7,
                    "grade_label": NSNull(), "grade_note": NSNull(), "title": "History essay",
                    "criteria": Self.criteria, "feedback": "A strong draft.",
                    "improvements": Self.improvements, "model": "claude-opus-5", "basis": "personal",
                    "rubric_name": NSNull(), "reused": false,
                ])
            case .loseAnswer:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .noConnection:
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            case .hold:
                runLoop = CFRunLoopGetCurrent()
                Self.state.hold(self)
            }
        } else if path.hasSuffix("/rest/v1/gradings") {
            respond(Self.state.nextSaved().map { id in
                [
                    "id": id.uuidString.lowercased(), "overall_marks": 5, "total_marks": 7,
                    "grade_label": NSNull(), "grade_note": NSNull(), "work_title": "History essay",
                    "breakdown": Self.criteria, "feedback": "Found on the server.",
                    "improvements": Self.improvements, "model": "claude-opus-5", "basis": "personal",
                ] as [String: Any]
            })
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    private func respond(_ json: Any) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// The marking screen while a marking runs, and the banner that finds the
/// student elsewhere when it is done, drawn to PNG files for a person to look
/// at. Off unless asked for, like the other snapshot suites.
@MainActor
@Suite("Marking snapshots", .serialized,
       .enabled(if: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"] != nil))
struct MarkingSnapshots {

    private actor FixedPlan: PlanReading {
        func fetch() async throws -> EntitlementService.Plan? { .freeFallback }
    }

    @MainActor
    private final class QuietAnnouncer: MarkingAnnouncer {
        var isAppActive: Bool { true }
        func notifyMarkingReady(gradingID: UUID, title: String?) {}
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
        try await Task.sleep(for: .seconds(1.5))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    @Test func markingYouCanLeave() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MarkingServer.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!,
                                           keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://marking-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        let marking = MarkingCoordinator(service: GradingService(client: client), announcer: QuietAnnouncer())
        let container = try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true))
        let context = container.mainContext
        let entitlements = EntitlementService(reader: FixedPlan())
        await entitlements.refresh()
        let work = String(repeating: "The treaty changed the balance of power in Europe. ", count: 40)

        func dressed(_ view: some View) -> some View {
            view
                .environment(marking)
                .environment(entitlements)
                .environment(AccountDeletion(defaults: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!))
                .environment(PlanCoordinator(plans: PlanService(client: nil), assignments: AssignmentService(client: nil)))
                .environment(Preferences())
                .environment(FocusSession())
                .environment(SessionService(client: nil, storage: storage))
                .environment(NotificationRouter())
                .modelContainer(container)
        }

        // 1. Back on the grader while a marking runs.
        MarkingServer.state.reset(grade: .hold)
        let running = Task {
            await marking.mark(work: work, rubricID: nil, assignment: nil, presentation: nil,
                               title: "History essay", isBlind: false, context: context,
                               mayStore: { true })
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while marking.current == nil, clock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try await render("1-marking-in-progress", dressed(NavigationStack { Screen { GraderScreen() } }))
        MarkingServer.state.releaseHeld()
        _ = await running.value

        // 2. Finished while the student was on Home.
        marking.isWatched = false
        MarkingServer.state.reset(grade: .answer)
        _ = await marking.mark(work: work, rubricID: nil, assignment: nil, presentation: nil,
                               title: "History essay", isBlind: false, context: context,
                               mayStore: { true })
        #expect(marking.ready != nil)
        try await render("2-feedback-ready-banner", dressed(AppShell()))
    }
}
