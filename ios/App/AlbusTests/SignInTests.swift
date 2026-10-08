import Testing
import Foundation
import Supabase
@testable import Albus

/// Signing in, signing out and deleting, against a scripted server.
///
/// Every test gets its own host, and the transport answers and records by
/// host, so no request from one test can reach another's script, and none can
/// reach a real server.
@Suite("Signing in", .serialized)
@MainActor
struct SignInTests {

    // MARK: - Apple

    @Test("Apple's ID token and nonce sign in, and the account says Apple")
    func appleSignIn() async throws {
        let server = Server()
        server.on("/auth/v1/token") { _ in .ok(Fixture.session(user: Fixture.appleUser)) }
        let session = server.sessionService()

        try await session.signInWithApple(idToken: "apple-id-token", nonce: "raw-nonce")

        let request = try #require(server.requests.first { $0.path == "/auth/v1/token" })
        #expect(request.query["grant_type"] == "id_token")
        #expect(request.json["provider"] as? String == "apple")
        #expect(request.json["id_token"] as? String == "apple-id-token")
        #expect(request.json["nonce"] as? String == "raw-nonce")
        #expect(request.json["link_identity"] as? Bool != true, "a new sign-in, not a link")
        #expect(session.state == .signedIn(userID: Fixture.appleUserID, isAnonymous: false))
        #expect(session.signInMethod == .apple)
        #expect(session.appleUserID == "apple-sub-001")
        #expect(session.arrival == .signedIn)
    }

    @Test("an account made before sign-in keeps its id when Apple is added")
    func appleLinksAnonymousAccount() async throws {
        let server = Server()
        server.on("/auth/v1/token") { _ in
            .ok(Fixture.session(user: Fixture.user(id: Fixture.anonymousUserID, anonymous: false,
                                                  identities: [Fixture.appleIdentity(userID: Fixture.anonymousUserID)])))
        }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.anonymousUser))
        await session.start()
        #expect(session.signInMethod == .anonymous)

        try await session.signInWithApple(idToken: "apple-id-token", nonce: "raw-nonce")

        let request = try #require(server.requests.first { $0.path == "/auth/v1/token" })
        #expect(request.json["link_identity"] as? Bool == true)
        #expect(request.headers["Authorization"] == "Bearer anonymous-access-token")
        #expect(session.userID == Fixture.anonymousUserID, "the same account, with everything in it")
        #expect(session.signInMethod == .apple)
    }

    @Test("an Apple ID with its own account is reported, and the phone stays as it was")
    func appleIDInUse() async throws {
        let server = Server()
        server.on("/auth/v1/token") { _ in .error(422, code: "identity_already_exists") }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.anonymousUser))
        await session.start()

        await #expect(throws: SignInError.appleIDInUse) {
            try await session.signInWithApple(idToken: "apple-id-token", nonce: "raw-nonce")
        }
        #expect(session.userID == Fixture.anonymousUserID)
        #expect(session.signInMethod == .anonymous)
    }

    @Test("switching to that Apple ID's own account signs in to it instead of linking")
    func switchToApple() async throws {
        let server = Server()
        server.on("/auth/v1/token") { _ in .ok(Fixture.session(user: Fixture.appleUser)) }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.anonymousUser))
        await session.start()

        try await session.switchToApple(idToken: "apple-id-token", nonce: "raw-nonce")

        let request = try #require(server.requests.first { $0.path == "/auth/v1/token" })
        #expect(request.json["link_identity"] as? Bool != true)
        #expect(session.userID == Fixture.appleUserID)
    }

    // MARK: - Signing out

    @Test("signing out leaves the phone signed out, with no pass to restore")
    func signOut() async throws {
        let server = Server()
        server.on("/auth/v1/token") { _ in .ok(Fixture.session(user: Fixture.appleUser)) }
        server.on("/auth/v1/logout") { _ in .ok("") }
        let session = server.sessionService()
        try await session.signInWithApple(idToken: "apple-id-token", nonce: "raw-nonce")

        try await session.signOut()

        #expect(session.state == .needsAccount)
        #expect(session.signInMethod == nil)
        #expect(session.appleUserID == nil)
        let restored = server.sessionService(storage: server.storage)
        await restored.start()
        #expect(restored.userID == nil, "nothing left to restore")
    }

    @Test("an account made before sign-in can't sign out: it would have no way back")
    func anonymousCannotSignOut() async throws {
        let server = Server()
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.anonymousUser))
        await session.start()
        await #expect(throws: SignInError.self) { try await session.signOut() }
        #expect(session.userID == Fixture.anonymousUserID)
    }

    // MARK: - Deletion

    @Test("deletion sends Apple's code when there is one, and only then")
    func deletionCarriesAppleCode() async throws {
        let server = Server()
        server.on("/functions/v1/delete-account") { _ in .ok(#"{"deleted":true,"apple_revoked":true}"#) }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.appleUser))
        await session.start()

        try await session.deleteRemoteAccount(appleAuthorizationCode: "apple-code")
        try await session.deleteRemoteAccount()

        let calls = server.requests.filter { $0.path == "/functions/v1/delete-account" }
        #expect(calls.count == 2)
        #expect(calls.first?.json["apple_authorization_code"] as? String == "apple-code")
        #expect(calls.last?.json["apple_authorization_code"] == nil)
        #expect(calls.allSatisfy { $0.method == "POST" })
    }

    @Test("the server's refusals arrive as refusals", arguments: [
        (428, "APPLE_REAUTH_REQUIRED", DeletionRefusal.needsApple),
        (400, "APPLE_CODE_INVALID", DeletionRefusal.appleCodeInvalid),
        (400, "APPLE_ACCOUNT_MISMATCH", DeletionRefusal.differentAppleID),
    ])
    func deletionRefusals(status: Int, code: String, refusal: DeletionRefusal) async throws {
        let server = Server()
        server.on("/functions/v1/delete-account") { _ in .raw(status, #"{"error":"\#(code)"}"#) }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.appleUser))
        await session.start()
        await #expect(throws: refusal) { try await session.deleteRemoteAccount() }
    }

    @Test("any other failure is not a refusal, and not proof the account is gone")
    func deletionOtherFailure() async throws {
        let server = Server()
        server.on("/functions/v1/delete-account") { _ in .raw(500, #"{"error":"INTERNAL_ERROR"}"#) }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.appleUser))
        await session.start()
        do {
            try await session.deleteRemoteAccount()
            Issue.record("a server error must not pass for a deletion")
        } catch {
            #expect(!(error is DeletionRefusal))
            #expect(!(error is AccountUnreachable))
        }
    }

    @Test("a refusal leaves no outstanding question and nothing cleared")
    func refusalClearsTheMark() async throws {
        let server = Server()
        server.on("/rest/v1/assignments") { _ in .ok("[]") }
        server.on("/functions/v1/delete-account") { _ in .raw(428, #"{"error":"APPLE_REAUTH_REQUIRED"}"#) }
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.appleUser))
        await session.start()
        let defaults = UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
        let deletion = AccountDeletion(defaults: defaults)
        var cleared = false

        let done = await deletion.perform(reachServer: { try await session.reachServer() },
                                          deleteRemote: { try await session.deleteRemoteAccount() },
                                          clearLocal: { cleared = true }, signOut: {})

        #expect(!done)
        #expect(!cleared)
        #expect(deletion.refused == .needsApple)
        #expect(deletion.errorMessage == DeletionRefusal.needsApple.message)
        #expect(!deletion.hasUnansweredRequest, "the server answered: nothing is outstanding")
        #expect(!deletion.requiresCleanup)
    }

    // MARK: - Messages

    @Test("server errors become the student's words, never the server's")
    func errorMapping() {
        func api(_ code: String) -> AuthError {
            .api(message: "server text", errorCode: ErrorCode(code), underlyingData: Data(),
                 underlyingResponse: HTTPURLResponse(url: URL(string: "https://x.invalid")!, statusCode: 400,
                                                     httpVersion: nil, headerFields: nil)!)
        }
        #expect(SignInError.from(api("over_request_rate_limit")) == .tooManyRequests)
        #expect(SignInError.from(api("identity_already_exists")) == .appleIDInUse)
        #expect(SignInError.from(api("email_exists")) == .appleIDInUse,
                "linking can meet the Apple ID's email on another account")
        #expect(SignInError.from(api("signup_disabled")) == .unavailable)
        #expect(SignInError.from(api("provider_disabled")) == .unavailable)
        #expect(SignInError.from(api("otp_expired")) == .other, "no codes any more")
        #expect(SignInError.from(api("something_new")) == .other)
        #expect(SignInError.from(URLError(.notConnectedToInternet)) == .offline)
        #expect(SignInError.from(SessionStorageUnavailable()) == .storage)
        for error in [SignInError.offline, .tooManyRequests, .appleIDInUse, .unavailable, .storage, .other] {
            let message = error.message ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("server text"))
        }
        #expect(SignInError.cancelled.message == nil, "cancelling says nothing")
    }

    /// The account is made on the sign-in screen, so the age rule and the
    /// terms are stated there. The sentence ends in the two pages, which are
    /// buttons; `LegalLinkDestinationsUITests` checks where each one goes.
    @Test("the sign-in screen states the age rule and the terms")
    func signInStatesTheTermsAndAge() {
        let text = SignInScreen.agreement
        #expect(text.contains("13 or older"))
        #expect(text.contains("under 16"))
        #expect(text.hasSuffix("you accept"))
    }

    @Test("an account with no Apple identity is not called Apple")
    func methodWithoutApple() async throws {
        let server = Server()
        let session = try server.sessionService(stored: Fixture.session(user: Fixture.emailUser))
        await session.start()
        #expect(session.userID == Fixture.emailUserID)
        #expect(session.signInMethod == .other)
    }

    @Test("each Apple attempt gets its own nonce, and its hash is SHA-256 hex")
    func nonce() {
        let first = AppleSignIn.makeNonce(), second = AppleSignIn.makeNonce()
        #expect(first.count == 32)
        #expect(first != second)
        #expect(AppleSignIn.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

// MARK: - Scripted server

private struct ScriptedRequest: Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data
    var json: [String: Any] {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
    }
}

private enum ScriptedResponse: Sendable {
    case ok(String)
    case raw(Int, String)
    case error(Int, code: String)
}

/// Answers by host, so tests can run side by side.
@MainActor
private final class Server {
    let host = "signin-\(UUID().uuidString.prefix(8).lowercased()).invalid"
    let keychain = MemoryKeychain()
    private(set) lazy var storage = ResilientAuthStorage(
        fallback: UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!, keychain: keychain)

    func on(_ path: String, _ answer: @escaping @Sendable (ScriptedRequest) -> ScriptedResponse) {
        ScriptedTransport.registry.set(host: host, path: path, answer: answer)
    }

    var requests: [ScriptedRequest] { ScriptedTransport.registry.requests(host: host) }

    func sessionService(storage: ResilientAuthStorage? = nil) -> SessionService {
        let storage = storage ?? self.storage
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedTransport.self]
        let client = SupabaseClient(
            supabaseURL: URL(string: "https://\(host)")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false),
                           global: .init(session: URLSession(configuration: config))))
        return SessionService(client: client, storage: storage)
    }

    /// A service whose phone already holds `stored`, as after an earlier launch.
    func sessionService(stored: String) throws -> SessionService {
        let label = host.split(separator: ".").first.map(String.init) ?? host
        try keychain.store(key: "sb-\(label)-auth-token", value: Data(stored.utf8))
        return sessionService()
    }
}

/// Accounts and sessions as GoTrue returns them.
private enum Fixture {
    static let appleUserID = UUID(uuidString: "a1000000-0000-4000-8000-000000000001")!
    static let emailUserID = UUID(uuidString: "e1000000-0000-4000-8000-000000000001")!
    static let anonymousUserID = UUID(uuidString: "a9000000-0000-4000-8000-000000000001")!

    static var appleUser: String {
        user(id: appleUserID, anonymous: false, email: "relay@privaterelay.appleid.com",
             identities: [appleIdentity(userID: appleUserID)])
    }
    static var emailUser: String {
        user(id: emailUserID, anonymous: false, email: "student@example.com",
             identities: [emailIdentity(userID: emailUserID)])
    }
    static var anonymousUser: String { user(id: anonymousUserID, anonymous: true, identities: []) }

    static func appleIdentity(userID: UUID) -> String {
        """
        {"identity_id":"\(UUID().uuidString.lowercased())","id":"apple-sub-001","user_id":"\(userID.uuidString.lowercased())","identity_data":{"sub":"apple-sub-001"},"provider":"apple","created_at":"2026-10-02T00:00:00Z","last_sign_in_at":"2026-10-02T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}
        """
    }

    static func emailIdentity(userID: UUID) -> String {
        """
        {"identity_id":"\(UUID().uuidString.lowercased())","id":"\(userID.uuidString.lowercased())","user_id":"\(userID.uuidString.lowercased())","identity_data":{"sub":"\(userID.uuidString.lowercased())","email":"student@example.com"},"provider":"email","created_at":"2026-10-02T00:00:00Z","last_sign_in_at":"2026-10-02T00:00:00Z","updated_at":"2026-10-02T00:00:00Z"}
        """
    }

    static func user(id: UUID, anonymous: Bool, email: String? = nil, identities: [String]) -> String {
        let emailField = email.map { #","email":"\#($0)""# } ?? ""
        return """
        {"id":"\(id.uuidString.lowercased())","aud":"authenticated","app_metadata":{},"user_metadata":{},"created_at":"2026-10-02T00:00:00Z","updated_at":"2026-10-02T00:00:00Z","is_anonymous":\(anonymous)\(emailField),"identities":[\(identities.joined(separator: ","))]}
        """
    }

    static func session(user: String) -> String {
        let token = user.contains(#""is_anonymous":true"#) ? "anonymous-access-token" : "unit-access-token"
        return """
        {"access_token":"\(token)","token_type":"bearer","expires_in":3600,"expires_at":\(Date().timeIntervalSince1970 + 3600),"refresh_token":"unit-refresh","user":\(user)}
        """
    }
}

private final class ScriptedTransport: URLProtocol, @unchecked Sendable {
    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String: [String: @Sendable (ScriptedRequest) -> ScriptedResponse]] = [:]
        private var log: [String: [ScriptedRequest]] = [:]

        func set(host: String, path: String, answer: @escaping @Sendable (ScriptedRequest) -> ScriptedResponse) {
            lock.lock(); defer { lock.unlock() }
            answers[host, default: [:]][path] = answer
        }
        func requests(host: String) -> [ScriptedRequest] {
            lock.lock(); defer { lock.unlock() }
            return log[host] ?? []
        }
        func handle(host: String, request: ScriptedRequest) -> ScriptedResponse {
            lock.lock(); defer { lock.unlock() }
            log[host, default: []].append(request)
            return answers[host]?[request.path]?(request) ?? .raw(404, #"{"error":"not scripted"}"#)
        }
    }

    static let registry = Registry()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let recorded = ScriptedRequest(method: request.httpMethod ?? "GET", path: url.path, query: query,
                                      headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        let (status, body): (Int, String)
        switch Self.registry.handle(host: url.host ?? "", request: recorded) {
        case .ok(let text): (status, body) = (200, text)
        case .raw(let code, let text): (status, body) = (code, text)
        case .error(let code, let errorCode):
            // GoTrue's current error shape, which the SDK reads only when the
            // response says it is API version 2024-01-01 or later.
            (status, body) = (code, #"{"code":"\#(errorCode)","message":"server text"}"#)
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json",
                           "X-Supabase-Api-Version": "2024-01-01"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
