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

    @MainActor @Test("transient refresh failures preserve the account and pending deletion", arguments: [0, 1, 2, 3])
    func transientRefresh(kind: Int) async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let transport: URLProtocol.Type = kind == 0 ? ServerFailureTransport.self
            : kind == 1 ? MalformedRefreshTransport.self
            : kind == 2 ? TimeoutRefreshTransport.self : OfflineRefreshTransport.self
        let client = Self.client(storage, transport: transport)
        let session = SessionService(client: client, storage: storage)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        await session.start()
        #expect(!session.credentialRejected)
        // The student stays in the account this phone holds, rather than
        // being sent to set-up, and the pass is renewed later.
        #expect(session.userID == Self.storedUserID)
        #expect(session.awaitingRenewal)
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(!deletion.requiresCleanup)
        #expect(client.auth.currentSession != nil)
        // Never a replacement account: creation keeps the one on screen.
        #expect(await session.createAccount())
        #expect(session.userID == Self.storedUserID)
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
        #expect(session.awaitingRenewal, "a temporary failure keeps the account and retries later")
        SwitchingRefreshTransport.mode.setRejected(true)
        // The retry, when the student comes back to the app.
        await session.revalidate()
        #expect(session.credentialRejected)
        #expect(session.state == .needsAccount)
        #expect(!session.awaitingRenewal)
        let deletion = AccountDeletion(defaults: defaults)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(deletion.requiresCleanup)
    }

    @MainActor @Test("a stored account opens at once, before the server renews its pass")
    func opensBeforeRenewal() async throws {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SlowRefreshTransport.self), storage: storage)
        let launch = Task { await session.start() }

        // The server takes 1.5 s to answer; the account is on screen long before.
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .milliseconds(500))
        while session.userID == nil, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(session.userID == Self.storedUserID)
        #expect(session.awaitingRenewal)

        await launch.value
        #expect(session.userID == Self.storedUserID)
        #expect(!session.awaitingRenewal, "the answer renews the pass")
        #expect(!session.credentialRejected)
    }

    @MainActor @Test("a pass that could not be renewed offline is renewed when the student comes back")
    func renewsOnReturn() async throws {
        RecoveringRefreshTransport.online.set(false)
        defer { RecoveringRefreshTransport.online.set(false) }
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RecoveringRefreshTransport.self), storage: storage)
        await session.start()
        #expect(session.awaitingRenewal)

        RecoveringRefreshTransport.online.set(true)
        await session.revalidate()
        #expect(!session.awaitingRenewal)
        #expect(session.userID == Self.storedUserID)
        #expect(!session.credentialRejected)
    }

    @MainActor @Test("coming back to the app asks nothing of the server once the pass is renewed")
    func revalidationIsFreeWhenCurrent() async throws {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: ForbiddenTransport.self), storage: storage)
        await session.start()
        await session.revalidate()
        await session.revalidate()
        #expect(session.userID == Self.storedUserID)
        #expect(!session.awaitingRenewal)
    }

    @MainActor @Test("with a deletion unanswered, launch waits for the server instead of showing the account")
    func unansweredDeletionWaits() async throws {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SlowRefreshTransport.self), storage: storage)
        let launch = Task { await session.start(opensEarly: false) }

        try await Task.sleep(for: .milliseconds(500))
        #expect(session.userID == nil, "the old account is not shown while its deletion is unsettled")
        #expect(session.state == .starting)

        await launch.value
        #expect(session.userID == Self.storedUserID)
    }

    @MainActor @Test("an unanswered deletion request is what keeps launch waiting")
    func unansweredRequestIsReported() {
        let requested = isolated()
        requested.set(true, forKey: "albus.accountDeletion.requested")
        #expect(AccountDeletion(defaults: requested).hasUnansweredRequest)

        #expect(!AccountDeletion(defaults: isolated()).hasUnansweredRequest)

        let settled = isolated()
        settled.set(true, forKey: "albus.accountDeletion.requested")
        settled.set(true, forKey: "albus.accountDeletion.pendingCleanup")
        #expect(!AccountDeletion(defaults: settled).hasUnansweredRequest,
                "a deletion being cleaned up is not waited on; cleanup has its own screen")
    }

    @MainActor @Test("purchases wait until the server has confirmed the account shown early")
    func purchasesWaitForConfirmation() async throws {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SlowRefreshTransport.self), storage: storage)
        let launch = Task { await session.start() }

        try await Task.sleep(for: .milliseconds(500))
        #expect(session.userID == Self.storedUserID, "shown early")
        #expect(session.confirmedUserID == nil, "not yet confirmed")

        await launch.value
        #expect(session.confirmedUserID == Self.storedUserID)
    }

    @MainActor @Test("a renewal answered after a sign-out does not bring the account back")
    func renewalCannotUndoSignOut() async throws {
        SignOutRaceTransport.online.set(false)
        defer { SignOutRaceTransport.online.set(false) }
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SignOutRaceTransport.self), storage: storage)
        await session.start()
        #expect(session.awaitingRenewal)

        SignOutRaceTransport.online.set(true)
        let renewal = Task { await session.revalidate() }
        try await Task.sleep(for: .milliseconds(150))
        try await session.signOutDeletedAccount()
        #expect(session.state == .needsAccount)

        await renewal.value
        #expect(session.state == .needsAccount, "the late answer is for an account signed out")
        #expect(session.userID == nil)
        #expect(!session.awaitingRenewal)
    }

    private func session(stored: Data, transport: URLProtocol.Type) throws -> SessionService {
        let keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: stored)
        let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
        return SessionService(client: Self.client(storage, transport: transport), storage: storage)
    }

    @MainActor @Test("the question before a deletion reaches the server without renewing a pass in date")
    func questionKeepsAPassInDate() async throws {
        RevokedSessionTransport.paths.reset()
        try await session(stored: SessionTestTransport.sessionData, transport: RevokedSessionTransport.self)
            .reachServer()
        let asked = RevokedSessionTransport.paths.all
        #expect(asked.contains { $0.hasSuffix("/rest/v1/assignments") }, "the server was asked")
        #expect(!asked.contains { $0.hasSuffix("/auth/v1/token") }, "the pass was left as it was")

        // No signal: an error, and never read as the account being gone.
        do {
            try await session(stored: SessionTestTransport.sessionData, transport: OfflineRefreshTransport.self)
                .reachServer()
            Issue.record("no signal must not pass for an answer")
        } catch {
            #expect(!(error is AccountUnreachable))
        }
        // An expired pass is renewed, as for any request, and a refusal then
        // means the account cannot be reached from this phone, as ever.
        do {
            try await session(stored: Self.expiredSessionData(), transport: RejectedRefreshTransport.self)
                .reachServer()
            Issue.record("a refused expired pass must not pass for an answer")
        } catch {
            #expect(error is AccountUnreachable)
        }
    }

    /// The reported bug: asking first renewed a pass in date, the server
    /// refused the renewal, the SDK dropped the pass the deletion could still
    /// have used, and the phone was cleared while the account stayed.
    @MainActor @Test("a pass the server will not renew still carries the deletion")
    func refusedRenewalNeverStandsInForDeletion() async throws {
        RevokedSessionTransport.paths.reset()
        let session = try session(stored: SessionTestTransport.sessionData, transport: RevokedSessionTransport.self)
        let deletion = AccountDeletion(defaults: isolated())
        var cleared = false

        let done = await deletion.perform(reachServer: { try await session.reachServer() },
                                          deleteRemote: { try await session.deleteRemoteAccount() },
                                          clearLocal: { cleared = true }, signOut: {})

        let asked = RevokedSessionTransport.paths.all
        #expect(asked.contains { $0.hasSuffix("/rest/v1/rpc/delete_my_account") }, "the deletion was sent")
        #expect(!asked.contains { $0.hasSuffix("/auth/v1/token") })
        #expect(done && cleared)
    }

    @MainActor @Test("launch notes when the server renewed the pass, and only then")
    func renewalIsNoted() async throws {
        func launch(stored: Data, transport: URLProtocol.Type, opensEarly: Bool = true) async throws -> SessionService {
            let keychain = MemoryKeychain()
            try keychain.store(key: "sb-session-unit-auth-token", value: stored)
            let storage = ResilientAuthStorage(fallback: isolated(), keychain: keychain)
            let session = SessionService(client: Self.client(storage, transport: transport), storage: storage)
            await session.start(opensEarly: opensEarly)
            return session
        }
        // A network that takes a moment, as every real one does. The SDK starts
        // renewing an expired pass itself as soon as the client exists; `start`
        // joins that renewal, and the answer is the server's either way. (Were
        // the SDK's to finish first, `start` would find the pass in date and
        // note nothing: the safe way to be wrong.)
        #expect(try await launch(stored: Self.expiredSessionData(), transport: SlowRefreshTransport.self).renewedByServer)
        #expect(try await launch(stored: Self.expiredSessionData(), transport: SlowRefreshTransport.self,
                                 opensEarly: false).renewedByServer)
        #expect(try await !launch(stored: SessionTestTransport.sessionData, transport: ForbiddenTransport.self).renewedByServer,
                "a pass in date was not asked about")
        #expect(try await !launch(stored: Self.expiredSessionData(), transport: OfflineRefreshTransport.self).renewedByServer,
                "no answer")
    }

    /// The fix for the reported bug, end to end: a request that went out and
    /// was never answered keeps launch waiting only until the server answers.
    @MainActor @Test("a launch the server answers settles an unanswered deletion either way")
    func launchSettlesUnansweredDeletion() async throws {
        func relaunch(transport: URLProtocol.Type, askedAgo: TimeInterval = 3600) async throws
            -> (SessionService, AccountDeletion) {
            let defaults = isolated(), keychain = MemoryKeychain()
            try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
            let deletion = AccountDeletion(defaults: defaults)
            #expect(await !deletion.perform(reachServer: {},
                                            deleteRemote: { throw URLError(.networkConnectionLost) },
                                            clearLocal: {}, signOut: {}))
            #expect(deletion.hasUnansweredRequest)
            // When the student asked, as far as this launch can tell.
            defaults.set(Date.now.addingTimeInterval(-askedAgo), forKey: "albus.accountDeletion.requestedAt")
            let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
            let session = SessionService(client: Self.client(storage, transport: transport), storage: storage)
            let relaunched = AccountDeletion(defaults: defaults)
            await session.start(settling: relaunched)
            return (session, relaunched)
        }

        // Renewed an hour on: the account exists, so the request deleted nothing.
        let (renewed, kept) = try await relaunch(transport: SlowRefreshTransport.self)
        #expect(renewed.userID == Self.storedUserID)
        #expect(!kept.hasUnansweredRequest && !kept.requiresCleanup)

        // Renewed a minute on: the server might still have been deleting it.
        let (soon, waiting) = try await relaunch(transport: SlowRefreshTransport.self, askedAgo: 60)
        #expect(soon.userID == Self.storedUserID)
        #expect(waiting.hasUnansweredRequest, "not settled by a renewal the deletion could follow")

        // Refused: the deletion happened, and cleanup starts.
        let (_, deleted) = try await relaunch(transport: RejectedRefreshTransport.self)
        #expect(deleted.requiresCleanup)

        // No signal: still unanswered, and still nothing erased.
        let (_, unsure) = try await relaunch(transport: OfflineRefreshTransport.self)
        #expect(unsure.hasUnansweredRequest && !unsure.requiresCleanup)
    }

    @MainActor @Test("launch waits for the server while a deletion is unanswered")
    func settlingLaunchWaits() async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let deletion = AccountDeletion(defaults: defaults)
        #expect(await !deletion.perform(reachServer: {},
                                        deleteRemote: { throw URLError(.timedOut) },
                                        clearLocal: {}, signOut: {}))
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SlowRefreshTransport.self), storage: storage)
        let launch = Task { await session.start(settling: AccountDeletion(defaults: defaults)) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.userID == nil, "not opened onto an account that may be gone")
        await launch.value
        #expect(session.userID == Self.storedUserID)
    }

    /// The reported bug: asking first leaves a fresh pass, so after a lost
    /// answer the next launch found the pass in date and never asked.
    @MainActor @Test("with a deletion unanswered, launch asks the server even about a pass in date")
    func unansweredLaunchAsksAboutFreshPass() async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        defaults.set(Date.now.addingTimeInterval(-60), forKey: "albus.accountDeletion.requestedAt")
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RejectedRefreshTransport.self),
                                     storage: storage)
        let deletion = AccountDeletion(defaults: defaults)

        await session.start(settling: deletion)

        #expect(session.credentialRejected, "only the server could say, the pass being in date")
        #expect(deletion.requiresCleanup)
        #expect(session.userID == nil, "the old account's plans are not shown")
    }

    @MainActor @Test("with a deletion unanswered and no answer, the account opens as it would offline")
    func unansweredWithoutAnswerOpensAwaiting() async throws {
        SwitchingRefreshTransport.mode.setRejected(false)
        defer { SwitchingRefreshTransport.mode.setRejected(false) }
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SwitchingRefreshTransport.self),
                                     storage: storage)
        let deletion = AccountDeletion(defaults: defaults)

        await session.start(settling: deletion)
        #expect(session.userID == Self.storedUserID, "their plans, not the set-up questions")
        #expect(session.awaitingRenewal)
        #expect(session.confirmedUserID == nil, "nothing acts for the account beyond the phone")
        #expect(deletion.hasUnansweredRequest && !deletion.requiresCleanup)

        // Back in the app, and this time the server refuses the pass: asked
        // again, though the pass is still in date.
        SwitchingRefreshTransport.mode.setRejected(true)
        await session.revalidate()
        #expect(session.credentialRejected)
        deletion.adoptLostDeletion(credentialRejected: session.credentialRejected)
        #expect(deletion.requiresCleanup)
    }

    @MainActor @Test("a return to the app whose renewal the server answers settles an old request",
                     arguments: [(3600.0, true), (60.0, false)])
    func foregroundRenewalSettles(askedAgo: TimeInterval, settles: Bool) async throws {
        RecoveringRefreshTransport.online.set(false)
        defer { RecoveringRefreshTransport.online.set(false) }
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: SessionTestTransport.sessionData)
        defaults.set(true, forKey: "albus.accountDeletion.requested")
        defaults.set(Date.now.addingTimeInterval(-askedAgo), forKey: "albus.accountDeletion.requestedAt")
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: RecoveringRefreshTransport.self),
                                     storage: storage)
        let deletion = AccountDeletion(defaults: defaults)

        await session.start(settling: deletion)
        #expect(session.awaitingRenewal, "launch had no answer")
        #expect(deletion.hasUnansweredRequest)

        RecoveringRefreshTransport.online.set(true)
        await session.revalidate(settling: deletion)
        #expect(!session.awaitingRenewal)
        #expect(deletion.hasUnansweredRequest == !settles,
                settles ? "an hour on: the request deleted nothing" : "a minute on: it might yet")
        #expect(!deletion.requiresCleanup)
    }

    /// With nothing outstanding the app opens at once, so a student can ask
    /// for a deletion before launch's renewal is answered. That renewal began
    /// before the request, so it proves nothing about it.
    @MainActor @Test("a renewal that began before a deletion request never settles it")
    func launchRenewalPredatesRequest() async throws {
        let defaults = isolated(), keychain = MemoryKeychain()
        try keychain.store(key: "sb-session-unit-auth-token", value: Self.expiredSessionData())
        let storage = ResilientAuthStorage(fallback: defaults, keychain: keychain)
        let session = SessionService(client: Self.client(storage, transport: SlowRefreshTransport.self), storage: storage)
        let deletion = AccountDeletion(defaults: defaults)
        let launch = Task { await session.start(settling: deletion) }
        try await Task.sleep(for: .milliseconds(500))
        #expect(session.userID == Self.storedUserID, "opened before the 1.5 s renewal")

        #expect(await !deletion.perform(reachServer: {},
                                        deleteRemote: { throw URLError(.networkConnectionLost) },
                                        clearLocal: {}, signOut: {}))
        #expect(deletion.hasUnansweredRequest)

        await launch.value
        #expect(session.renewedByServer)
        #expect(deletion.hasUnansweredRequest, "still unanswered: the renewal was asked before it")
        #expect(!deletion.requiresCleanup)
    }

    private static let storedUserID = UUID(uuidString: "a9400000-0000-4000-8000-000000000001")!

    /// A session this phone stored more than an hour ago: its pass has expired.
    private static func expiredSessionData() throws -> Data {
        var payload = try #require(JSONSerialization.jsonObject(with: SessionTestTransport.sessionData) as? [String: Any])
        payload["expires_at"] = Date().timeIntervalSince1970 - 3600
        return try JSONSerialization.data(withJSONObject: payload)
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

/// No connection at all, as in airplane mode.
private final class OfflineRefreshTransport: ServerFailureTransport, @unchecked Sendable {
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
}

/// A slow network: renews the pass, but only after 1.5 s.
private final class SlowRefreshTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var timer: Timer?
    override func startLoading() {
        // On the loading thread's own run loop, where the answer belongs.
        let timer = Timer(timeInterval: 1.5, repeats: false) { [weak self] _ in self?.answer() }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }
    private func answer() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: SessionTestTransport.sessionData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { timer?.invalidate() }
}

/// Offline until `online` is set, then renews the pass.
private final class RecoveringRefreshTransport: URLProtocol, @unchecked Sendable {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set(_ newValue: Bool) { lock.lock(); defer { lock.unlock() }; value = newValue }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let online = Flag()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        #expect(request.url?.path != "/auth/v1/signup")
        guard Self.online.isSet else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: SessionTestTransport.sessionData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// The server after a session is revoked: a pass still in date is accepted,
/// renewing it is refused, and deleting the account succeeds. Records every
/// path asked for.
private final class RevokedSessionTransport: URLProtocol, @unchecked Sendable {
    final class PathLog: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [String] = []
        func reset() { lock.lock(); defer { lock.unlock() }; value = [] }
        func add(_ path: String) { lock.lock(); defer { lock.unlock() }; value.append(path) }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let paths = PathLog()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        Self.paths.add(path)
        if path.hasSuffix("/auth/v1/token") {
            respond(status: 400, body: #"{"error_code":"refresh_token_not_found","msg":"Revoked"}"#)
        } else if path.hasSuffix("/rpc/delete_my_account") {
            respond(status: 204, body: "")
        } else {
            respond(status: 200, body: "[]")
        }
    }
    private func respond(status: Int, body: String) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Fails the test if anything reaches the network.
private final class ForbiddenTransport: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Issue.record("unexpected request to \(request.url?.path ?? "?")")
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// Offline until `online`; then signing out is answered at once and renewing
/// the pass takes 1.2 s, so a sign-out can land while a renewal is in flight.
private final class SignOutRaceTransport: URLProtocol, @unchecked Sendable {
    static let online = RecoveringRefreshTransport.Flag()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    private var timer: Timer?
    override func startLoading() {
        #expect(request.url?.path != "/auth/v1/signup")
        guard Self.online.isSet else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if request.url?.path.hasSuffix("/logout") == true {
            respond(status: 204, body: Data())
            return
        }
        let timer = Timer(timeInterval: 1.2, repeats: false) { [weak self] _ in
            self?.respond(status: 200, body: SessionTestTransport.sessionData)
        }
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }
    private func respond(status: Int, body: Data) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { timer?.invalidate() }
}
