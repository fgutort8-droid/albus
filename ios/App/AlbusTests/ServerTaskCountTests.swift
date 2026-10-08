import Testing
import Foundation
import SwiftData
import Supabase
@testable import Albus

/// The server's count of open tasks, kept honest from the phone.
///
/// The free plan caps open tasks on the server, and tasks live on the phone.
/// Finishing a task has to reach the server, or a student who finished five is
/// refused a sixth; and tasks on another phone are freed only when the student
/// says so, because only they know whether that phone is still in use.
@Suite("The server's count of open tasks", .serialized)
@MainActor
struct ServerTaskCountTests {

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)))
    }

    @discardableResult
    private func task(_ context: ModelContext, remoteID: UUID?, status: AssignmentStatus,
                      updatedAt: Date = Date(timeIntervalSince1970: 1_790_000_000), steps: Int = 0) -> Assignment {
        let assignment = Assignment(title: "Task", taskType: "essay",
                                    deadline: Date(timeIntervalSince1970: 1_800_000_000), estimatedMinutes: 60)
        assignment.remoteID = remoteID
        assignment.statusValue = status
        context.insert(assignment)
        for i in 0..<steps {
            context.insert(Subtask(title: "Step \(i)", ordinal: i, estimatedMinutes: 30, assignment: assignment))
        }
        assignment.updatedAt = updatedAt
        try? context.save()
        return assignment
    }

    // MARK: - Finishing

    @Test("every way a task finishes or opens again is reported, once each")
    func statusChangesSignal() throws {
        let context = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil), assignments: AssignmentService(client: nil))
        let known = task(context, remoteID: UUID(), status: .active, steps: 2)
        let steps = known.subtasks.sorted { $0.ordinal < $1.ordinal }

        coordinator.setCompleted(steps[0], true, context: context)
        #expect(coordinator.statusChangesOnPhone == 0, "one step done is not a finished task")
        coordinator.setCompleted(steps[1], true, context: context)
        #expect(coordinator.statusChangesOnPhone == 1, "finished")
        #expect(known.statusValue == .completed)
        coordinator.setCompleted(steps[1], false, context: context)
        #expect(coordinator.statusChangesOnPhone == 2, "opened again by undoing a step")
        #expect(known.statusValue == .active)
        coordinator.deleteStep(steps[1], context: context)
        #expect(coordinator.statusChangesOnPhone == 3, "finished by deleting the step that was still open")
        #expect(known.statusValue == .completed)
        coordinator.addStep(to: known, title: "One more", minutes: 20, context: context)
        #expect(coordinator.statusChangesOnPhone == 4, "opened again by a new step")

        let unsent = task(context, remoteID: nil, status: .active, steps: 1)
        coordinator.setCompleted(unsent.subtasks[0], true, context: context)
        #expect(coordinator.statusChangesOnPhone == 4, "the server has no copy of it to change")
    }

    @Test("the phone reports only its own finished and open tasks, the most recent first")
    func whatThePhoneReports() throws {
        let context = try store()
        let recent = UUID(), older = UUID(), open = UUID(), refused = UUID()
        task(context, remoteID: older, status: .completed, updatedAt: Date(timeIntervalSince1970: 1_780_000_000))
        task(context, remoteID: recent, status: .completed, updatedAt: Date(timeIntervalSince1970: 1_790_000_000))
        task(context, remoteID: open, status: .active)
        task(context, remoteID: refused, status: .archived)
        task(context, remoteID: nil, status: .completed)
        task(context, remoteID: nil, status: .active)

        #expect(PlanCoordinator.finishedRemoteIDs(in: context) == [recent, older])
        #expect(PlanCoordinator.openRemoteIDs(in: context) == [open])
    }

    // MARK: - Tasks on another phone

    @Test("freeing other tasks is offered only when they are what stops a new task here")
    func whenToOffer() {
        let f = PlanCoordinator.uncountedOnPhone
        #expect(f(5, 5, 0, 0) == 5, "a new phone, with the plan full of tasks from the old one")
        #expect(f(5, 5, 2, 2) == 3)
        #expect(f(5, 5, 2, 1) == 4, "a task the AI is still writing is here but not yet on the server")
        #expect(f(5, 5, 5, 5) == 0, "this phone's own tasks fill the plan: freeing others would not help")
        #expect(f(5, 5, 5, 4) == 0, "still full of this phone's own, one of them still being written")
        #expect(f(3, 5, 0, 0) == 0, "below the cap, other tasks cost nothing")
        #expect(f(9, nil, 0, 0) == 0, "an unlimited plan")
        #expect(f(0, 0, 0, 0) == 0, "a plan without tasks")
    }

    // MARK: - The server calls

    @Test("the phone's finished and open tasks are sent by id; nothing to send sends nothing; a failure is nil")
    func syncCall() async throws {
        let server = TaskServer()
        server.answer("sync_my_assignments", status: 200, body: "2")
        let service = AssignmentService(client: server.client)
        let finished = [UUID(), UUID()], open = [UUID()]

        #expect(await service.sync(finished: finished, open: open) == 2)
        let call = try #require(server.calls.first)
        #expect(call.path == "/rest/v1/rpc/sync_my_assignments")
        #expect(call.method == "POST")
        #expect(call.list("p_finished") == finished.map { $0.uuidString.lowercased() })
        #expect(call.list("p_open") == open.map { $0.uuidString.lowercased() })

        #expect(await service.sync(finished: [], open: []) == 0)
        #expect(server.calls.count == 1, "nothing to send, nothing sent")

        server.answer("sync_my_assignments", status: 500, body: #"{"message":"down"}"#)
        #expect(await service.sync(finished: finished, open: open) == nil)
    }

    @Test("freeing other tasks keeps this phone's open ones, and a failure throws")
    func releaseCall() async throws {
        let server = TaskServer()
        server.answer("release_my_other_assignments", status: 200, body: "3")
        let service = AssignmentService(client: server.client)
        let keep = [UUID()]

        #expect(try await service.releaseOthers(keeping: keep) == 3)
        let call = try #require(server.calls.first)
        #expect(call.path == "/rest/v1/rpc/release_my_other_assignments")
        #expect(call.list("p_keep") == keep.map { $0.uuidString.lowercased() })

        _ = try await service.releaseOthers(keeping: [])
        #expect(server.calls.last?.list("p_keep") == [], "an empty phone keeps nothing")

        server.answer("release_my_other_assignments", status: 500, body: #"{"message":"down"}"#)
        await #expect(throws: (any Error).self) { try await service.releaseOthers(keeping: keep) }
    }

    @Test("the phone's tasks reach the server before the plan is read, and the count is settling until then")
    func syncOrder() async throws {
        let context = try store()
        let finished = UUID(), open = UUID()
        task(context, remoteID: finished, status: .completed)
        task(context, remoteID: open, status: .active)
        let server = TaskServer()
        server.answer("sync_my_assignments", status: 200, body: "1")
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        var settlingDuringRefresh = false
        var callsBeforeRefresh = -1

        await coordinator.syncServerCount(context: context) {
            settlingDuringRefresh = coordinator.serverCountSettling
            callsBeforeRefresh = server.calls.count
        }

        #expect(callsBeforeRefresh == 1)
        #expect(server.calls.first?.list("p_finished") == [finished.uuidString.lowercased()])
        #expect(server.calls.first?.list("p_open") == [open.uuidString.lowercased()])
        #expect(settlingDuringRefresh, "the banner holds off until the plan is read back")
        #expect(!coordinator.serverCountSettling)
    }

    @Test("stop counting keeps exactly the tasks open on this phone, then reads the plan")
    func releaseKeepsThisPhone() async throws {
        let context = try store()
        let open = UUID()
        task(context, remoteID: open, status: .active)
        task(context, remoteID: UUID(), status: .completed)
        task(context, remoteID: nil, status: .active)
        let server = TaskServer()
        server.answer("release_my_other_assignments", status: 200, body: "4")
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        var refreshed = false

        try await coordinator.releaseOthers(context: context) { refreshed = true }

        #expect(server.calls.first?.list("p_keep") == [open.uuidString.lowercased()])
        #expect(refreshed)
        #expect(!coordinator.serverCountSettling)
    }

    @Test("a change while a sync is on its way is sent after it, never beside it, and the latest wins")
    func syncsQueue() async throws {
        let context = try store()
        let id = UUID()
        let assignment = task(context, remoteID: id, status: .active)
        let server = TaskServer()
        server.answer("sync_my_assignments", status: 200, body: "1")
        let held = server.holdFirstAnswer()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        let counter = RefreshCounter()

        let first = Task { await coordinator.syncServerCount(context: context) { counter.count += 1 } }
        for _ in 0..<300 where server.calls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(server.calls.count == 1, "the first request is on its way, held")

        assignment.statusValue = .completed
        await coordinator.syncServerCount(context: context) { counter.count += 1 }
        #expect(server.calls.count == 1, "nothing is sent beside a request on its way")

        held.signal()
        await first.value

        #expect(server.calls.count == 2)
        #expect(server.calls.last?.list("p_finished") == [id.uuidString.lowercased()], "the latest picture goes last")
        #expect(server.calls.last?.list("p_open") == [])
        #expect(counter.count == 1, "the plan is read once, after the last request")
        #expect(!coordinator.serverCountSettling)
    }

    @Test("a change while the plan is being read back is sent next, and the plan read again")
    func changeDuringRefreshIsSent() async throws {
        let context = try store()
        let id = UUID()
        let assignment = task(context, remoteID: id, status: .active)
        let server = TaskServer()
        server.answer("sync_my_assignments", status: 200, body: "1")
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        let counter = RefreshCounter()

        await coordinator.syncServerCount(context: context) {
            counter.count += 1
            guard counter.count == 1 else { return }
            // The student finishes the task while the plan is on its way back,
            // and the change asks for a sync, as RootView does.
            assignment.statusValue = .completed
            await coordinator.syncServerCount(context: context) { counter.count += 1 }
        }

        #expect(server.calls.count == 2, "the change made during the read is sent")
        #expect(server.calls.last?.list("p_finished") == [id.uuidString.lowercased()])
        #expect(server.calls.last?.list("p_open") == [])
        #expect(counter.count == 2, "and the plan is read again after it")
        #expect(!coordinator.serverCountSettling)
    }

    @Test("an account that was deleted sends nothing")
    func deletedAccountSendsNothing() async throws {
        let context = try store()
        task(context, remoteID: UUID(), status: .completed)
        let server = TaskServer()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        coordinator.invalidateForAccountDeletion()
        var refreshed = false

        await coordinator.syncServerCount(context: context) { refreshed = true }
        try await coordinator.releaseOthers(context: context) { refreshed = true }

        #expect(server.calls.isEmpty)
        #expect(!refreshed)
    }
}

@MainActor
private final class RefreshCounter {
    var count = 0
}

// MARK: - A scripted server

/// Answers by host, so no test can reach another's script, or a real server.
@MainActor
private final class TaskServer {
    let host = "tasks-\(UUID().uuidString.prefix(8).lowercased()).invalid"

    struct Call: Sendable {
        let method: String
        let path: String
        let body: Data
        func list(_ key: String) -> [String]? {
            (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?[key] as? [String]
        }
    }

    var calls: [Call] { TaskTransport.registry.calls(host: host) }

    func answer(_ function: String, status: Int, body: String) {
        TaskTransport.registry.set(host: host, path: "/rest/v1/rpc/\(function)", status: status, body: body)
    }

    /// Holds the answer to the next request until the test signals, as a
    /// slow network would.
    func holdFirstAnswer() -> DispatchSemaphore {
        TaskTransport.registry.hold(host: host)
    }

    private(set) lazy var client: SupabaseClient = {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [TaskTransport.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!,
                                           keychain: MemoryKeychain())
        return SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
    }()
}

private final class TaskTransport: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [String: (Int, String)]] = [:]
        private var log: [String: [TaskServer.Call]] = [:]
        private var holds: [String: DispatchSemaphore] = [:]

        func set(host: String, path: String, status: Int, body: String) {
            lock.lock(); defer { lock.unlock() }
            answers[host, default: [:]][path] = (status, body)
        }
        func calls(host: String) -> [TaskServer.Call] {
            lock.lock(); defer { lock.unlock() }
            return log[host] ?? []
        }
        func hold(host: String) -> DispatchSemaphore {
            lock.lock(); defer { lock.unlock() }
            let semaphore = DispatchSemaphore(value: 0)
            holds[host] = semaphore
            return semaphore
        }
        /// Records the call, and hands back a hold for it if one is waiting.
        func record(host: String, call: TaskServer.Call) -> (answer: (Int, String)?, hold: DispatchSemaphore?) {
            lock.lock(); defer { lock.unlock() }
            log[host, default: []].append(call)
            return (answers[host]?[call.path], holds.removeValue(forKey: host))
        }
    }
    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host?.hasSuffix(".invalid") == true && request.url?.host?.hasPrefix("tasks-") == true
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host else { return }
        let call = TaskServer.Call(method: request.httpMethod ?? "GET", path: url.path, body: bodyData())
        let recorded = Self.registry.record(host: host, call: call)
        // A held answer waits here, on the loading thread, not the test's.
        recorded.hold?.wait()
        let (status, body) = recorded.answer ?? (404, #"{"message":"no script"}"#)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    private func bodyData() -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
