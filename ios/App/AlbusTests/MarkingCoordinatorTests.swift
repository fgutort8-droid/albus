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
                             recoveryWindow: TimeInterval = 5,
                             save: @escaping @MainActor (ModelContext) throws -> Void = { try $0.save() })
        -> MarkingCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MarkingServer.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!,
                                           keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://marking-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return MarkingCoordinator(service: GradingService(client: client), announcer: announcer,
                                  recoveryWindow: recoveryWindow, pollInterval: .milliseconds(40),
                                  save: save)
    }

    private func mark(_ coordinator: MarkingCoordinator, context: ModelContext,
                      assignment: Assignment? = nil,
                      mayStore: Bool = true) async -> MarkingCoordinator.Outcome {
        await coordinator.mark(work: work, rubricID: nil, assignment: assignment, presentation: nil,
                               title: "History essay", isBlind: false, context: context,
                               mayStore: { mayStore })
    }

    /// The test work's length as the server records it: run through the
    /// server's own `normaliseWork`, it is the sentence six times over, less
    /// the trailing space the phone trims before sending.
    private static let serverLength = 305

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

    @Test("a lost answer with nothing saved is asked for once more after the window, then fails")
    func lostAnswerWithNothingSavedFails() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[]])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer, recoveryWindow: 0.3)

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .failed(.unavailable))
        #expect(try stored(context).isEmpty)
        #expect(MarkingServer.state.gradeRequests == 2, "once, then once more after the window, never sooner")
        #expect(MarkingServer.state.lookups > 1, "it kept looking until the window closed")
        #expect(coordinator.ready == nil)
    }

    /// The reported bug: the server answers identical work from the result it
    /// already holds, which may be old and for another assignment, so no new
    /// row appears for recovery to find. Asked again, it answers from it free.
    @Test("a lost answer the server gave from a saved result is recovered by asking again")
    func reusedResultFoundByAskingAgain() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, then: .answer, saved: [[]])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer, recoveryWindow: 0.3)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.remoteID == Self.markedID)
        #expect(MarkingServer.state.gradeRequests == 2)
        #expect(coordinator.ready == grading.id)
    }

    @Test("a result already on the phone is opened, not stored twice")
    func askingAgainFindsAResultAlreadyKept() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, then: .answer, saved: [[]])
        let context = try store(), announcer = RecordingAnnouncer()
        let kept = Grading(remoteID: Self.markedID, model: "claude-opus-5", inputChars: 300,
                           overallMarks: 6, totalMarks: 7, gradeLabel: nil, gradeNote: nil,
                           workTitle: "History essay", criteria: [], feedback: "A strong draft.",
                           improvements: [], basis: .personal, assignment: nil)
        context.insert(kept)
        try context.save()
        let coordinator = coordinator(announcer, recoveryWindow: 0.3)

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .marked(kept.id))
        #expect(try stored(context).count == 1)
    }

    @Test("offline through the window, the work is not sent again")
    func offlineRecoveryDoesNotAskAgain() async throws {
        MarkingServer.state.reset(grade: .loseAnswer, then: .answer, saved: [[]])
        MarkingServer.state.lookupsOffline(true)
        defer { MarkingServer.state.lookupsOffline(false) }
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer, recoveryWindow: 0.3)

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .failed(.offline))
        #expect(MarkingServer.state.gradeRequests == 1)
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

    /// The reported bug: the newest grading in the window was taken, whatever
    /// work it was for.
    @Test("recovery takes this work's grading, never a newer one of other work")
    func recoveryMatchesTheWork() async throws {
        let otherWork = UUID(), otherAssignment = UUID()
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[], [Self.savedID]], others: [
            .init(id: otherWork, inputChars: Self.serverLength + 9, assignmentID: nil),
            .init(id: otherAssignment, inputChars: Self.serverLength, assignmentID: UUID()),
        ])
        let context = try store(), announcer = RecordingAnnouncer()
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.remoteID == Self.savedID)
        #expect(try stored(context).count == 1, "nothing of the other work's is kept")
        let asked = try #require(MarkingServer.state.lookupFilters.first)
        #expect(asked["input_chars"] == "eq.\(Self.serverLength)", "as long as the server measured it")
        #expect(asked["assignment_id"] == "is.null")
        #expect(MarkingServer.state.gradeRequests == 1)
    }

    @Test("recovery for an assignment looks only at that assignment's gradings")
    func recoveryMatchesTheAssignment() async throws {
        let context = try store(), announcer = RecordingAnnouncer()
        let assignment = Assignment(title: "History essay", taskType: "essay",
                                    deadline: .now.addingTimeInterval(86_400), estimatedMinutes: 60)
        assignment.remoteID = UUID()
        context.insert(assignment)
        try context.save()
        MarkingServer.state.reset(grade: .loseAnswer, saved: [[], [Self.savedID]], others: [
            .init(id: UUID(), inputChars: Self.serverLength, assignmentID: nil),
        ])
        let coordinator = coordinator(announcer)

        let outcome = await mark(coordinator, context: context, assignment: assignment)

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.remoteID == Self.savedID)
        #expect(grading.assignment?.id == assignment.id)
        let asked = try #require(MarkingServer.state.lookupFilters.first)
        #expect(asked["assignment_id"] == "eq.\(try #require(assignment.remoteID).uuidString)")
    }

    @Test("a result the phone could not save is neither announced nor left behind")
    func failedSaveIsNotAnnounced() async throws {
        MarkingServer.state.reset(grade: .answer)
        let context = try store(), announcer = RecordingAnnouncer()
        announcer.isAppActive = false
        let coordinator = coordinator(announcer, save: { _ in throw CocoaError(.fileWriteOutOfSpace) })

        let outcome = await mark(coordinator, context: context)

        #expect(outcome == .failed(.notSaved))
        #expect(try stored(context).isEmpty, "no half-kept grading for a later save to pick up")
        #expect(announcer.notified.isEmpty, "a notification would open onto nothing")
        #expect(coordinator.ready == nil)
        #expect(GradingService.Failure.notSaved.errorDescription?.contains("won't be charged twice") == true)
    }

    /// The student can leave while the work is marked, and delete the
    /// assignment it was for.
    @Test("an assignment deleted during the marking leaves the result in history, unlinked")
    func deletedAssignmentKeepsTheResult() async throws {
        MarkingServer.state.reset(grade: .hold)
        let context = try store(), announcer = RecordingAnnouncer()
        let assignment = Assignment(title: "History essay", taskType: "essay",
                                    deadline: .now.addingTimeInterval(86_400), estimatedMinutes: 60)
        context.insert(assignment)
        try context.save()
        let coordinator = coordinator(announcer)

        let marking = Task { await mark(coordinator, context: context, assignment: assignment) }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while MarkingServer.state.gradeRequests == 0, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(50))
        context.delete(assignment)
        try context.save()
        MarkingServer.state.answerHeld()
        let outcome = await marking.value

        let grading = try #require(try stored(context).first)
        #expect(outcome == .marked(grading.id))
        #expect(grading.assignment == nil)
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

/// `GradingService.serverLength(of:)` must agree with the server to the unit:
/// recovery finds a lost marking by it. Every expected value here is what the
/// server's own `normaliseWork` returned for the input, run with Deno.
@Suite("The server's measure of the work")
struct ServerLengthTests {
    static let cases: [(String, String, Int)] = [
        ("Plain text.", "Plain text.", 11),
        ("  Leading and trailing  \n\n", "Leading and trailing", 20),
        ("Windows\r\nline\rendings\r\n", "Windows\nline\nendings", 20),
        ("soft\u{00AD}hyphen", "softhyphen", 10),
        ("Para one.\n12\nPara two.\n  3  \nPara three.", "Para one.\n\nPara two.\n\nPara three.", 33),
        ("The year\n2024 was\nlong.", "The year\n2024 was\nlong.", 23),
        ("Tabs\t\tand   spaces", "Tabs and spaces", 15),
        ("Line one  \n   Line two", "Line one\nLine two", 17),
        ("One\n\n\n\n\nTwo", "One\n\nTwo", 8),
        ("\u{00A0}\u{FEFF}BOM and NBSP\u{00A0}", "BOM and NBSP", 12),
        ("Arabic digits\n\u{0661}\u{0662}\nstay", "Arabic digits\n\u{0661}\u{0662}\nstay", 21),
        ("Emoji \u{1F600} and \u{00E9}\n\nnext", "Emoji \u{1F600} and \u{00E9}\n\nnext", 20),
        ("Page\n12345\nfive digits stay", "Page\n12345\nfive digits stay", 27),
        ("Sep\u{2028}line", "Sep\u{2028}line", 8),
        ("\u{0085}Next line\u{0085}", "\u{0085}Next line\u{0085}", 11)
    ]

    @Test("normalised exactly as the server does it", arguments: 0..<cases.count)
    func matchesTheServer(index: Int) {
        let (input, output, length) = Self.cases[index]
        #expect(GradingService.serverNormalised(input) == output)
        #expect(GradingService.serverNormalised(input).utf16.count == length)
    }

    @Test("the length is taken after the phone's own trim, as sent")
    func lengthOfWhatIsSent() {
        #expect(GradingService.serverLength(of: "  Para one.\n12\nPara two.  \n") == 20)
        #expect(GradingService.serverLength(of: "Emoji 😀") == 8, "UTF-16 units, as JavaScript counts")
    }
}

/// The server, for these tests only. `grade` answers, loses its answer or has
/// no connection; each read of `gradings` returns the next saved set. Nothing
/// reaches a real server.
private final class MarkingServer: URLProtocol, @unchecked Sendable {
    enum Grade { case answer, loseAnswer, noConnection, hold }

    /// A grading of some other work, saved in the same minutes.
    struct Other: Sendable {
        let id: UUID
        let inputChars: Int
        let assignmentID: UUID?
    }

    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var grade: Grade = .answer
        private var saved: [[UUID]] = [[]]
        private var grades = 0
        private var reads = 0
        private var held: [MarkingServer] = []
        private var others: [Other] = []
        private var filters: [[String: String]] = []

        /// `saved` are this work's gradings, appearing read by read; `others`
        /// are newer gradings of other work, there from the start.
        /// `then`, when given, answers every marking after the first.
        func reset(grade: Grade, then: Grade? = nil, saved: [[UUID]] = [[]], others: [Other] = []) {
            lock.lock(); defer { lock.unlock() }
            self.grade = grade; self.later = then; self.saved = saved; grades = 0; reads = 0; held = []
            self.others = others; filters = []; offlineLookups = false
        }
        private var later: Grade?
        private var offlineLookups = false
        /// Reads of `gradings` fail as they do with no signal.
        func lookupsOffline(_ offline: Bool) { lock.lock(); defer { lock.unlock() }; offlineLookups = offline }
        var lookupsAreOffline: Bool { lock.lock(); defer { lock.unlock() }; return offlineLookups }
        var otherGradings: [Other] { lock.lock(); defer { lock.unlock() }; return others }
        func record(_ query: [String: String]) {
            lock.lock(); defer { lock.unlock() }
            filters.append(query)
        }
        /// What each read of `gradings` filtered on.
        var lookupFilters: [[String: String]] { lock.lock(); defer { lock.unlock() }; return filters }
        /// Answers every held marking, as a slow server finally would.
        func answerHeld() {
            lock.lock()
            let waiting = held
            held = []
            lock.unlock()
            waiting.forEach { $0.answerOnLoadingThread() }
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
            return grades > 1 ? (later ?? grade) : grade
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

    fileprivate func answerOnLoadingThread() {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [self] in answerMarking() }
        CFRunLoopWakeUp(runLoop)
    }

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
                answerMarking()
            case .loseAnswer:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .noConnection:
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            case .hold:
                runLoop = CFRunLoopGetCurrent()
                Self.state.hold(self)
            }
        } else if path.hasSuffix("/rest/v1/gradings") {
            if Self.state.lookupsAreOffline {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            // As PostgREST would: newest first, then the filters, then one.
            var query: [String: String] = [:]
            for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
                query[item.name] = item.value
            }
            Self.state.record(query)
            // A filter the app leaves out restricts nothing, as in PostgREST.
            let others = Self.state.otherGradings.filter { other in
                (query["input_chars"].map { $0 == "eq.\(other.inputChars)" } ?? true)
                    && (query["assignment_id"].map {
                        $0 == (other.assignmentID.map { "eq.\($0.uuidString)" } ?? "is.null")
                    } ?? true)
            }
            let found = others.map(\.id) + Self.state.nextSaved()
            respond(found.prefix(1).map { id in
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

    private func answerMarking() {
        respond([
            "id": "6a6a0000-0000-4000-8000-000000000001", "overall_marks": 6, "total_marks": 7,
            "grade_label": NSNull(), "grade_note": NSNull(), "title": "History essay",
            "criteria": Self.criteria, "feedback": "A strong draft.",
            "improvements": Self.improvements, "model": "claude-opus-5", "basis": "personal",
            "rubric_name": NSNull(), "reused": false,
        ])
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
