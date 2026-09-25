import Testing
import Foundation
import Security
import Supabase
@testable import Albus

@Suite("Session storage")
struct SessionStorageTests {
    private func isolated() -> UserDefaults {
        UserDefaults(suiteName: "albus.tests.\(UUID().uuidString)")!
    }

    @Test("a session round-trips through secure storage")
    func roundTrips() throws {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain())
        let value = Data("session-bytes".utf8)
        try storage.store(key: "session", value: value)
        #expect(try storage.retrieve(key: "session") == value)
    }

    @Test("a new instance reads what an earlier one wrote")
    func survivesNewInstance() throws {
        let shared = isolated(), keychain = MemoryKeychain()
        let value = Data("session-bytes".utf8)
        try ResilientAuthStorage(fallback: shared, keychain: keychain).store(key: "session", value: value)
        #expect(try ResilientAuthStorage(fallback: shared, keychain: keychain).retrieve(key: "session") == value)
    }

    @Test("removal clears both stores and is idempotent")
    func removalIsComplete() throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        try storage.store(key: "session", value: Data("x".utf8))
        defaults.set(Data("old".utf8), forKey: "albus.auth.session")
        try storage.remove(key: "session")
        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
        #expect(defaults.data(forKey: "albus.auth.session") == nil)
    }

    @Test("a missing key returns nil rather than throwing")
    func missingKeyIsNotAnError() throws {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain())
        #expect(try storage.retrieve(key: "never-written") == nil)
    }

    @Test("legacy credentials migrate without leaving plaintext", arguments: ["sb-session-unit-auth-token", "supabase.session"])
    func legacyMigration(key: String) throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        let data = Data("legacy-session".utf8)
        defaults.set(data, forKey: "albus.auth." + key)
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        #expect(try storage.retrieve(key: key) == data)
        #expect(try keychain.retrieve(key: key) == data)
        #expect(defaults.data(forKey: "albus.auth." + key) == nil)
    }

    @Test("secure credentials take precedence and remove stale plaintext")
    func securePrecedence() throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        defaults.set(Data("old".utf8), forKey: "albus.auth.session")
        try keychain.store(key: "session", value: Data("current".utf8))
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        #expect(try storage.retrieve(key: "session") == Data("current".utf8))
        #expect(defaults.data(forKey: "albus.auth.session") == nil)
    }

    @Test("unavailable Keychain never writes plaintext")
    func failedWrite() {
        let defaults = isolated(), keychain = MemoryKeychain(failure: .write)
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        #expect(throws: SessionStorageUnavailable.self) { try storage.store(key: "session", value: Data("secret".utf8)) }
        #expect(defaults.data(forKey: "albus.auth.session") == nil)
        #expect(throws: SessionStorageUnavailable.self) { try storage.checkHealth() }
    }

    @Test("failed reads and migrations never return plaintext", arguments: [MemoryKeychain.Failure.read, .write])
    func failedMigration(failure: MemoryKeychain.Failure) throws {
        let defaults = isolated(), keychain = MemoryKeychain(failure: failure)
        defaults.set(Data("secret".utf8), forKey: "albus.auth.session")
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        #expect(throws: SessionStorageUnavailable.self) { try storage.retrieve(key: "session") }
        #expect(defaults.data(forKey: "albus.auth.session") == Data("secret".utf8))
        // A later healthy launch must still migrate the original account.
        let retry = ResilientAuthStorage(fallback: defaults, keychain: MemoryKeychain())
        #expect(try retry.retrieve(key: "session") == Data("secret".utf8))
        #expect(defaults.data(forKey: "albus.auth.session") == nil)
    }

    @Test("failed deletion is surfaced")
    func failedRemoval() {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain(failure: .remove))
        #expect(throws: SessionStorageUnavailable.self) { try storage.remove(key: "session") }
        #expect(throws: SessionStorageUnavailable.self) { try storage.checkHealth() }
    }

    @Test("a successful older read cannot hide a failed write")
    func failureStaysLatched() throws {
        let keychain = MemoryKeychain(failure: .write)
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        _ = try? storage.store(key: "session", value: Data([1]))
        _ = try storage.retrieve(key: "session")
        #expect(throws: SessionStorageUnavailable.self) { try storage.checkHealth() }
    }

    @Test("accessibility preserves background refresh and existing sessions")
    func accessibility() {
        #expect(SessionKeychain.accessibility == kSecAttrAccessibleAfterFirstUnlock)
    }

    @Test("startup migrates every prefixed credential")
    func allCopies() throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        for key in ["supabase.session", "sb-session-unit-auth-token", "older-project"] {
            defaults.set(Data([1]), forKey: "albus.auth." + key)
        }
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        try storage.beginAttempt()
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("albus.auth.") })
    }

    @MainActor @Test("storage unavailability does not confirm a pending account deletion")
    func unavailableIsNotDeletion() async {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain(failure: .read))
        let client = Self.client(storage)
        let session = SessionService(client: client, storage: storage)
        await session.start()
        #expect(session.credentialRejected == false)
        #expect(session.userID == nil)
        let defaults = isolated()
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(!deletion.requiresCleanup)
    }

    @MainActor @Test("SDK-swallowed credential writes cannot report signed-in")
    func swallowedWrite() async {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain(failure: .authWrite))
        let session = SessionService(client: Self.client(storage), storage: storage)
        #expect(await session.createAccount() == false)
        #expect(session.userID == nil)
    }

    @MainActor @Test("server refresh rejection still settles a lost deletion response")
    func serverRejection() async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RejectedRefreshTransport.self), storage: storage)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        await session.start()
        #expect(session.credentialRejected)
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(deletion.requiresCleanup)
    }

    @MainActor @Test("normal creation and restore keep the same account")
    func sdkRoundTrip() async {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain())
        let client = Self.client(storage)
        let session = SessionService(client: client, storage: storage)
        #expect(await session.createAccount())
        let restored = SessionService(client: Self.client(storage), storage: storage)
        await restored.start()
        #expect(restored.userID == session.userID)
        #expect(restored.userID != nil)
    }

    @MainActor @Test("SDK-swallowed removal errors keep cleanup pending")
    func swallowedRemoval() async throws {
        let keychain = MemoryKeychain(failure: .remove)
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage), storage: storage)
        await session.start()
        #expect(session.userID != nil)
        await #expect(throws: SessionStorageUnavailable.self) { try await session.signOutDeletedAccount() }
        #expect(session.userID != nil)
    }

    private static func client(_ storage: ResilientAuthStorage, transport: URLProtocol.Type = SessionTestTransport.self) -> SupabaseClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [transport]
        return SupabaseClient(supabaseURL: URL(string: "https://session-unit.invalid")!, supabaseKey: "unit-placeholder",
            options: .init(auth: .init(storage: storage, autoRefreshToken: false), global: .init(session: URLSession(configuration: config))))
    }
}

final class MemoryKeychain: AuthLocalStorage, @unchecked Sendable {
    enum Failure: Sendable { case none, read, write, remove, authWrite }
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private let failure: Failure
    init(failure: Failure = .none) { self.failure = failure }
    func store(key: String, value: Data) throws {
        lock.lock(); defer { lock.unlock() }
        if failure == .write || (failure == .authWrite && !key.hasPrefix("albus.storage-probe.")) { throw SessionStorageUnavailable() }
        values[key] = value
    }
    func retrieve(key: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failure == .read { throw SessionStorageUnavailable() }
        return values[key]
    }
    func remove(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failure == .remove { throw SessionStorageUnavailable() }
        values.removeValue(forKey: key)
    }
}

/// Intercepts every request. No request from these tests can reach a server.
private final class SessionTestTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    static var sessionData: Data {
        let json = """
        {"access_token":"unit-token","token_type":"bearer","expires_in":3600,"expires_at":\(Date().timeIntervalSince1970 + 3600),"refresh_token":"unit-refresh","user":{"id":"a9400000-0000-4000-8000-000000000001","aud":"authenticated","app_metadata":{},"user_metadata":{},"created_at":"2026-09-25T00:00:00Z","updated_at":"2026-09-25T00:00:00Z","is_anonymous":true}}
        """
        return Data(json.utf8)
    }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.sessionData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class RejectedRefreshTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error_code":"refresh_token_not_found","msg":"Mock refresh rejection"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
