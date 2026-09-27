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
        #expect(await session.createAccount() == false)
        #expect(session.userID == nil)
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

    @MainActor @Test("deletion retries after transient storage failure")
    func deletionRetry() async throws {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage), storage: storage)
        await session.start()
        keychain.setFailure(.read)
        _ = try? storage.retrieve(key: "sb-session-unit-auth-token")
        keychain.setFailure(.none)
        try await session.deleteRemoteAccount()
    }

    @MainActor @Test("creation retries validate an expired stored session")
    func expiredCreationRetry() async throws {
        let keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RejectedRefreshTransport.self), storage: storage)
        #expect(await session.createAccount() == false)
        #expect(session.userID == nil)
    }

    @MainActor @Test("transient refresh failures preserve the account and pending deletion", arguments: [0, 1, 2])
    func transientRefresh(kind: Int) async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let transport: URLProtocol.Type = kind == 0 ? ServerFailureTransport.self
            : kind == 1 ? MalformedRefreshTransport.self : TimeoutRefreshTransport.self
        let client = Self.client(storage, transport: transport)
        let session = SessionService(client: client, storage: storage)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        await session.start()
        #expect(!session.credentialRejected)
        if case .failed = session.state {} else { Issue.record("Transient failure must offer retry, not account replacement") }
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(!deletion.requiresCleanup)
        #expect(client.auth.currentSession != nil)
        #expect(await session.createAccount() == false)
        do {
            try await session.deleteRemoteAccount()
            Issue.record("Transient authentication must not confirm deletion")
        } catch {
            #expect(!(error is AccountUnreachable))
        }
    }

    @MainActor @Test("ordinary credential absence is not a confirmed deletion")
    func ordinaryAbsence() async {
        let defaults = isolated()
        let storage = ResilientAuthStorage(fallback: defaults, keychain: MemoryKeychain())
        let session = SessionService(client: Self.client(storage), storage: storage)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        await session.start()
        #expect(session.state == .needsAccount)
        #expect(!session.credentialRejected)
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(!deletion.requiresCleanup)
    }

    @MainActor @Test("terminal refresh rejection remains provable after SDK cleanup")
    func initialRefreshRace() async throws {
        let keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let client = Self.client(storage, transport: RejectedRefreshTransport.self)
        _ = try? await client.auth.session
        #expect(client.auth.currentSession == nil)
        let session = SessionService(client: client, storage: storage)
        await session.start()
        #expect(session.credentialRejected)
        #expect(session.state == .needsAccount)
    }

    @Test("remembered refresh credentials remain scoped to the SDK storage key")
    func observedCredentialScope() throws {
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: MemoryKeychain())
        try storage.store(key: "project-a", value: SessionTestTransport.sessionData)
        _ = try storage.retrieve(key: "project-a")
        try storage.remove(key: "project-a")
        #expect(try storage.recoveryRefreshToken() != nil)
        _ = try storage.retrieve(key: "project-b")
        #expect(try storage.recoveryRefreshToken() == nil)
        try storage.clearRecovery()
        _ = try storage.retrieve(key: "project-b")
        #expect(try storage.recoveryRefreshToken() == nil)
    }

    @MainActor @Test("SDK-encoded credentials retain terminal rejection provenance")
    func sdkEncodedRecovery() async throws {
        let keychain = MemoryKeychain()
        var value = try AuthClient.Configuration.jsonDecoder.decode(Session.self, from: SessionTestTransport.sessionData)
        value.expiresAt = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONEncoder().encode(value))
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let client = Self.client(storage, transport: RejectedRefreshTransport.self)
        _ = try? await client.auth.session
        #expect(client.auth.currentSession == nil)
        let session = SessionService(client: client, storage: storage)
        await session.start()
        #expect(session.credentialRejected)
    }

    @MainActor @Test("rejection recovery survives recreating storage and client")
    func durableRejectionRecovery() async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        do {
            let firstStorage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
            let firstClient = Self.client(firstStorage, transport: RejectedRefreshTransport.self)
            _ = try? await firstClient.auth.session
            #expect(firstClient.auth.currentSession == nil)
        }
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RejectedRefreshTransport.self), storage: storage)
        await session.start()
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(deletion.requiresCleanup)
    }

    @Test("replacement credentials retire recovery copies and confirmed cleanup removes them")
    func recoveryLifecycle() throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        try storage.store(key: "project", value: SessionTestTransport.sessionData)
        _ = try storage.retrieve(key: "project")
        try storage.remove(key: "project")
        #expect(try storage.recoveryRefreshToken() == "unit-refresh")
        try storage.store(key: "project", value: SessionTestTransport.sessionData)
        #expect(try storage.recoveryRefreshToken() == nil)
        try storage.remove(key: "project")
        try storage.clearRecovery()
        #expect(try storage.recoveryRefreshToken() == nil)
        #expect(try keychain.retrieve(key: "albus.recovery.project") == nil)
        #expect(!defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("albus.auth.") })
    }

    @MainActor @Test("a terminal rejection during retry permits pending deletion recovery")
    func terminalDuringRetry() async throws {
        SwitchingRefreshTransport.mode.setRejected(false)
        defer { SwitchingRefreshTransport.mode.setRejected(false) }
        let defaults = isolated(), keychain = MemoryKeychain()
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        try keychain.store(key: "sb-session-unit-auth-token", value: JSONSerialization.data(withJSONObject: payload))
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SwitchingRefreshTransport.self), storage: storage)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        await session.start()
        #expect(!session.credentialRejected)
        if case .failed = session.state {} else { Issue.record("Temporary failure should offer retry") }
        SwitchingRefreshTransport.mode.setRejected(true)
        #expect(await session.createAccount() == false)
        #expect(session.credentialRejected)
        #expect(session.state == .needsAccount)
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(deletion.requiresCleanup)
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
    private var failure: Failure
    func setFailure(_ value: Failure) {
        lock.lock(); defer { lock.unlock() }
        failure = value
    }
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

private class ServerFailureTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    var status: Int { 500 }
    var body: Data { Data(#"{"code":"unexpected_failure","message":"Synthetic server failure"}"#.utf8) }
    override func startLoading() {
        #expect(request.url?.path != "/auth/v1/signup")
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
private final class MalformedRefreshTransport: ServerFailureTransport, @unchecked Sendable {
    override var status: Int { 200 }
    override var body: Data { Data("{broken-response".utf8) }
}
private final class TimeoutRefreshTransport: ServerFailureTransport, @unchecked Sendable {
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
    }
}

private final class SwitchingRefreshTransport: URLProtocol, @unchecked Sendable {
    final class Mode: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func setRejected(_ rejected: Bool) { lock.lock(); defer { lock.unlock() }; value = rejected }
        var rejected: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let mode = Mode()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path != "/auth/v1/signup")
        if !Self.mode.rejected {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error_code":"refresh_token_not_found","msg":"Synthetic rejection"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
