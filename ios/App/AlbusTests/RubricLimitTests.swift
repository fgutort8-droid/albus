import Foundation
import Supabase
import Testing
@testable import Albus

/// The rubric limit at the server's end: a rubric past the plan's limit is
/// saved on the phone and turned away by `assert_rubric_limits`. The student
/// must be told that, not that a sync failed and might work next time.
@MainActor
@Suite("Rubric limit", .serialized)
struct RubricLimitTests {

    @Test("the plan-limit refusal reads as a plan limit, not a failed sync")
    func planLimitRefusal() async {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlanLimitTransport.self]
        let storage = ResilientAuthStorage(
            fallback: UserDefaults(suiteName: "albus.rubric-limit.\(UUID())")!,
            keychain: MemoryKeychain())
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://rubric-limit-unit.invalid")!,
            supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        let service = RubricService(client: client, log: { _ in })

        do {
            try await service.save(.init(id: UUID(), name: "Fourth rubric", source: "custom",
                                         body: nil, totalMarks: nil, items: []))
            Issue.record("A refused rubric must not look saved")
        } catch {
            #expect((error as? RubricService.Failure) == .planLimit)
        }

        let message = RubricService.Failure.planLimit.errorDescription ?? ""
        #expect(!message.contains("Couldn't sync"))
        #expect(message.contains("move up a plan"))
    }

    @Test("only the plan limit is read as one")
    func otherRefusalsKeepTheirMeaning() {
        #expect(RubricService.isPlanLimit(PostgrestError(code: "Q0011", message: "RUBRIC_PLAN_LIMIT")))
        // The 200-rubric safety ceiling, and the 40-criterion cap, are not
        // something a plan buys more of.
        #expect(!RubricService.isPlanLimit(PostgrestError(code: "Q0012", message: "RUBRIC_CEILING")))
        #expect(!RubricService.isPlanLimit(PostgrestError(code: "23514",
                                                          message: "rubric criterion limit reached")))
        #expect(!RubricService.isPlanLimit(PostgrestError(message: "no code")))
    }
}

/// Answers every request the way PostgREST answers a rubric past the plan's
/// limit: 400, with the trigger's SQLSTATE as the code.
private final class PlanLimitTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = #"{"code":"Q0011","message":"RUBRIC_PLAN_LIMIT","details":null,"hint":null}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
