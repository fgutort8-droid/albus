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

    @Test("finishing the last step of a task the server knows signals once; undoing does not")
    func finishingSignals() throws {
        let context = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil), assignments: AssignmentService(client: nil))
        let known = task(context, remoteID: UUID(), status: .active, steps: 2)
        let steps = known.subtasks.sorted { $0.ordinal < $1.ordinal }

        coordinator.setCompleted(steps[0], true, context: context)
        #expect(coordinator.finishedOnPhone == 0, "one step done is not a finished task")
        coordinator.setCompleted(steps[1], true, context: context)
        #expect(coordinator.finishedOnPhone == 1)
        #expect(known.statusValue == .completed)
        coordinator.setCompleted(steps[1], false, context: context)
        #expect(coordinator.finishedOnPhone == 1, "reopening is not reported")

        let unsent = task(context, remoteID: nil, status: .active, steps: 1)
        coordinator.setCompleted(unsent.subtasks[0], true, context: context)
        #expect(coordinator.finishedOnPhone == 1, "the server has no copy of it to close")
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

    @Test("finished tasks are sent by id, an empty list sends nothing, and a failure is reported as nil")
    func finishCall() async throws {
        let server = TaskServer()
        server.answer("finish_my_assignments", status: 200, body: "2")
        let service = AssignmentService(client: server.client)
        let ids = [UUID(), UUID()]

        #expect(await service.finish(remoteIDs: ids) == 2)
        let call = try #require(server.calls.first)
        #expect(call.path == "/rest/v1/rpc/finish_my_assignments")
        #expect(call.method == "POST")
        #expect(call.list("p_ids") == ids.map { $0.uuidString.lowercased() })

        #expect(await service.finish(remoteIDs: []) == 0)
        #expect(server.calls.count == 1, "nothing to send, nothing sent")

        server.answer("finish_my_assignments", status: 500, body: #"{"message":"down"}"#)
        #expect(await service.finish(remoteIDs: ids) == nil)
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

    @Test("the finished tasks reach the server before the plan is read, and the count is settling until then")
    func syncOrder() async throws {
        let context = try store()
        let finished = UUID()
        task(context, remoteID: finished, status: .completed)
        let server = TaskServer()
        server.answer("finish_my_assignments", status: 200, body: "1")
        let coordinator = PlanCoordinator(plans: PlanService(client: nil),
                                          assignments: AssignmentService(client: server.client))
        var settlingDuringRefresh = false
        var callsBeforeRefresh = -1

        await coordinator.syncServerCount(context: context) {
            settlingDuringRefresh = coordinator.serverCountSettling
            callsBeforeRefresh = server.calls.count
        }

        #expect(callsBeforeRefresh == 1)
        #expect(server.calls.first?.list("p_ids") == [finished.uuidString.lowercased()])
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

        func set(host: String, path: String, status: Int, body: String) {
            lock.lock(); defer { lock.unlock() }
            answers[host, default: [:]][path] = (status, body)
        }
        func calls(host: String) -> [TaskServer.Call] {
            lock.lock(); defer { lock.unlock() }
            return log[host] ?? []
        }
        func record(host: String, call: TaskServer.Call) -> (Int, String)? {
            lock.lock(); defer { lock.unlock() }
            log[host, default: []].append(call)
            return answers[host]?[call.path]
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
        let (status, body) = Self.registry.record(host: host, call: call) ?? (404, #"{"message":"no script"}"#)
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
