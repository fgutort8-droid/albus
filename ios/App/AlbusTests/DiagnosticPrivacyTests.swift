import Foundation
import Supabase
import Testing
@testable import Albus

@MainActor
@Suite("Diagnostic privacy", .serialized)
struct DiagnosticPrivacyTests {
    @Test("backend error details stay out of application diagnostics", arguments: [0, 1, 2])
    func backendFailure(kind: Int) async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiagnosticErrorTransport.self]
        let defaults = UserDefaults(suiteName: "albus.diagnostic.test.\(UUID())")!
        let storage = ResilientAuthStorage(fallback: defaults, keychain: MemoryKeychain())
        let client = SupabaseClient(supabaseURL: URL(string: "https://diagnostic-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false), global: .init(session: URLSession(configuration: config))))
        let recorder = DiagnosticRecorder()
        if kind == 2 {
            let result = await ProfileService(client: client, log: recorder.record).createCourse(displayName: "Synthetic course", colorKey: "green")
            #expect(result == nil)
        } else {
            let service = RubricService(client: client, log: recorder.record)
            do {
                if kind == 0 { try await service.delete(id: UUID()) }
                else { try await service.save(.init(id: UUID(), name: "Synthetic rubric", source: "custom", body: nil, totalMarks: nil, items: [])) }
                Issue.record("Synthetic backend rejection must remain an error")
            } catch {
                #expect((error as? RubricService.Failure) == .unavailable)
            }
        }
        #expect(recorder.messages.count == 1)
        #expect(!recorder.messages.joined().contains("SENTINEL_STUDENT_CONTENT"))
    }
    @Test("successful and offline writes retain their existing outcomes", arguments: [false, true])
    func ordinaryResponses(offline: Bool) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [offline ? DiagnosticOfflineTransport.self : DiagnosticSuccessTransport.self]
        let storage = ResilientAuthStorage(fallback: UserDefaults(suiteName: "albus.diagnostic.control.\(UUID())")!, keychain: MemoryKeychain())
        let client = SupabaseClient(supabaseURL: URL(string: "https://diagnostic-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false), global: .init(session: URLSession(configuration: config))))
        let recorder = DiagnosticRecorder()
        let rubric = RubricService(client: client, log: recorder.record)
        for deleting in [false, true] {
            do {
                if deleting { try await rubric.delete(id: UUID()) }
                else { try await rubric.save(.init(id: UUID(), name: "Synthetic", source: "custom", body: nil, totalMarks: nil, items: [])) }
                #expect(!offline)
            } catch { #expect(offline && (error as? RubricService.Failure) == .offline) }
        }
        let course = await ProfileService(client: client, log: recorder.record).createCourse(displayName: "Synthetic", colorKey: "green")
        #expect(offline ? course == nil : course == UUID(uuidString: "a9700000-0000-4000-8000-000000000001"))
        #expect(recorder.messages.count == (offline ? 1 : 0))
    }

}

private final class DiagnosticRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ message: String) { lock.lock(); defer { lock.unlock() }; values.append(message) }
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
}

private final class DiagnosticErrorTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"code":"23514","message":"SENTINEL_STUDENT_CONTENT","details":"SENTINEL_STUDENT_CONTENT","hint":"SENTINEL_STUDENT_CONTENT"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class DiagnosticSuccessTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = request.url?.path.hasSuffix("create_course") == true
            ? "\"a9700000-0000-4000-8000-000000000001\"" : "[]"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class DiagnosticOfflineTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
