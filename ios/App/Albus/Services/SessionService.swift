import Foundation
import Supabase

/// The account cannot be reached from this device any more.
///
/// Thrown instead of the underlying rejection so the deletion flow can stay
/// free of SDK error types, and so the one case that means "already gone"
/// cannot be confused with the several that mean "try again later".
struct AccountUnreachable: Error {}

/// Restores the account this phone holds, and signs students in.
///
/// Students sign in before anything else, with Apple or with a code sent by
/// email (the owner's decision, 2 Oct 2026). Accounts made before that were
/// anonymous; they still open, and keep their data when Apple or an email is
/// added to them. The session must stay durable either way: it is what the
/// phone's plans and the free allowance belong to.
@Observable
@MainActor
final class SessionService {

    enum State: Equatable {
        case starting
        /// No stored session. Onboarding runs and creates the account at the
        /// end, which is the only point a CAPTCHA challenge can be presented.
        case needsAccount
        case signedIn(userID: UUID, isAnonymous: Bool)
        case failed(String)
    }

    private(set) var state: State = .starting

    /// Set when restoring the session failed because the credential was
    /// refused, rather than because the phone could not reach the server.
    ///
    /// The difference decides whether a deletion whose answer was lost may be
    /// treated as done. An anonymous account has no second way in: once its
    /// refresh token is refused, nothing on this device can reach it again. A
    /// phone in a tunnel proves nothing and must never be read that way, so a
    /// network failure deliberately leaves this false.
    private(set) var credentialRejected = false

    /// True while the account on screen came from this phone's storage and the
    /// server has not renewed its pass yet, because the phone was offline or the
    /// server did not answer. The pass had expired, or a deletion the student
    /// asked for is unanswered. `revalidate()` asks again.
    private(set) var awaitingRenewal = false

    /// True when the last `start()` renewed the stored pass with the server,
    /// which proves the account existed then. A pass still in date is used
    /// without asking, and proves nothing.
    private(set) var renewedByServer = false
    /// When that renewal was asked for.
    private(set) var renewalBegan: Date?

    /// A renewal is in flight. Keeps `revalidate()` from racing `start()`.
    private var renewing = false

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    /// How the signed-in account signs in. Nil when signed out.
    enum SignInMethod: Equatable {
        case apple
        case email(String)
        /// Made before sign-in existed. Adding Apple or an email saves it.
        case anonymous
        /// Signed in, but the session does not say how.
        case other
    }

    private(set) var signInMethod: SignInMethod?

    /// Whether the account signed in now was restored at launch or signed in
    /// on the sign-in screen. `LocalAccount` treats the phone's data
    /// differently for each.
    private(set) var arrival: LocalAccount.Arrival = .restored

    /// Apple's identifier for the student, to ask Apple whether they have
    /// since stopped using Sign in with Apple for Albus.
    private(set) var appleUserID: String?

    /// The address an email code was last sent to by `sendEmailCode`, and
    /// whether that code adds the address to an anonymous account rather than
    /// signing in.
    private var pendingEmail: (address: String, addsToAccount: Bool)?

    /// The account once the server has confirmed its pass. Whatever acts for
    /// the account beyond this phone, such as the App Store's purchase
    /// identity, waits for this: a stored account shown early may turn out to
    /// have been deleted. The plans already on the phone need only `userID`.
    var confirmedUserID: UUID? { awaitingRenewal ? nil : userID }

    private let client: SupabaseClient?
    private let storage: ResilientAuthStorage

    init(client: SupabaseClient? = Backend.shared, storage: ResilientAuthStorage = Backend.authStorage) {
        self.client = client
        self.storage = storage
    }

    /// Restores an existing session. Does **not** create one.
    ///
    /// Restore is tried first and deliberately: signing in again when a valid
    /// session already exists would orphan the previous account and hand the
    /// caller a clean quota, which is exactly the abuse the Keychain-backed
    /// session exists to prevent.
    ///
    /// Creation is a separate, explicit step (`createAccount`) because it is
    /// the only moment a CAPTCHA challenge can be attached. Creating an account
    /// silently at launch, as this used to, is precisely what makes account
    /// farming a one-line script.
    ///
    /// - Parameter opensEarly: false while a deletion the student asked for is
    ///   unanswered. Its account may already be gone, so launch asks the server,
    ///   even about a pass still in date, and waits for the answer rather than
    ///   show its plans or buy under it. With no answer at all, offline say,
    ///   the account opens as any does offline: awaiting renewal, with nothing
    ///   acting for it beyond the phone, and the next return asks again.
    func start(opensEarly: Bool = true) async {
#if DEBUG
        // UI tests that exercise post-onboarding screens must not create a real
        // account (or spend a real AI call merely to reach the tab bar). This
        // switch is compiled out of Release and grants no server credential:
        // it changes presentation state only, while every backend still
        // requires its own authenticated session.
        if ProcessInfo.processInfo.arguments.contains("-albus.debug.assumeSignedIn") {
            state = .signedIn(
                userID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                isAnonymous: false
            )
            signInMethod = .email("student@example.com")
            return
        }
        // The sign-in screen, whatever this simulator's Keychain holds.
        if ProcessInfo.processInfo.arguments.contains("-albus.debug.assumeSignedOut") {
            signedOut(as: .needsAccount)
            return
        }
#endif
        guard let client else {
            state = .failed("Not configured")
            return
        }
        credentialRejected = false
        renewedByServer = false
        renewalBegan = nil
        arrival = .restored
        renewing = true
        defer { renewing = false }
        var shown = state
        do {
            try storage.beginAttempt()
            // An account this phone already holds opens at once. Its pass
            // expires an hour after it was issued and renewing it needs the
            // server, but the plans are on the phone. Waiting showed a blank
            // screen for as long as the network took, and offline it sent the
            // student to the set-up questions instead of their plans. A pass
            // still in date never waited, and this treats an expired one the
            // same way. The launch sequence still awaits this function, so
            // nothing that needs the server runs before the renewal settles.
            if opensEarly, let stored = client.auth.currentSession, stored.isExpired {
                try storage.checkHealth()
                adopt(stored.user)
                awaitingRenewal = true
            }
            shown = state
            let began = Date.now
            let (session, renewed) = try await Self.validatedSession(client, storage: storage,
                                                                     renew: !opensEarly)
            // Settled some other way while the server answered, by a sign-out
            // after a deletion say: that stands.
            guard state == shown else { return }
            try storage.checkHealth()
            adopt(session.user)
            awaitingRenewal = false
            renewedByServer = renewed
            renewalBegan = renewed ? began : nil
        } catch {
            guard state == shown else { return }
            // Kept back for the server's answer, and there was none. The stored
            // account opens awaiting renewal, as it would have offline; a
            // refused pass or none at all is settled below as ever.
            if !opensEarly, let stored = client.auth.currentSession {
                adopt(stored.user)
                awaitingRenewal = true
            }
            settle(restoreFailure: error)
        }
    }

    /// Renews a pass that `start()` could not, once the student is back in the
    /// app. Always with the server, even for a pass in date: what is awaited is
    /// its answer. A refused pass is handled exactly as at launch; a network
    /// failure changes nothing, and the next return to the app tries again.
    ///
    /// - Returns: when the renewal was asked for, if the server renewed the pass.
    @discardableResult
    func revalidate() async -> Date? {
        guard awaitingRenewal, !renewing, let client, case .signedIn = state else { return nil }
        let shown = state
        renewing = true
        defer { renewing = false }
        let began = Date.now
        do {
            try storage.beginAttempt()
            let (session, _) = try await Self.validatedSession(client, storage: storage, renew: true)
            // Signed out while this was in flight: the sign-out stands, and
            // an answer for the old pass must not bring the account back.
            guard state == shown else { return nil }
            try storage.checkHealth()
            adopt(session.user)
            awaitingRenewal = false
            return began
        } catch {
            guard state == shown else { return nil }
            settle(restoreFailure: error)
            return nil
        }
    }

    /// What a failed restore or renewal means for the student.
    private func settle(restoreFailure error: Error) {
        // No stored session, or it could not be refreshed. Which of those
        // it was matters to `AccountDeletion`: a refused credential is the
        // only evidence a phone has that a deletion it never heard back
        // about actually happened.
        guard (try? storage.checkHealth()) != nil else {
            awaitingRenewal = false
            signedOut(as: .failed(SessionStorageUnavailable().localizedDescription))
            return
        }
        if error is AccountUnreachable {
            awaitingRenewal = false
            credentialRejected = true
            signedOut(as: .needsAccount)
        } else if (error as? AuthError) == .sessionMissing {
            // No credential was available; absence alone proves no deletion.
            awaitingRenewal = false
            signedOut(as: .needsAccount)
        } else if awaitingRenewal {
            // The network failed, not the account. The student keeps their
            // plans, anything that needs the server fails the way it does
            // offline, and `revalidate()` tries again. Never read as a
            // deletion: a phone in a tunnel proves nothing.
        } else {
            signedOut(as: .failed("Couldn't restore your sign-in. Please try again."))
        }
    }

    private func adopt(_ user: User) {
        state = .signedIn(userID: user.id, isAnonymous: user.isAnonymous)
        signInMethod = Self.method(of: user)
        appleUserID = user.identities?.first { $0.provider == "apple" }.map(Self.appleSubject)
    }

    private func signedOut(as newState: State) {
        state = newState
        signInMethod = nil
        appleUserID = nil
        pendingEmail = nil
    }

    static func method(of user: User) -> SignInMethod {
        if user.isAnonymous { return .anonymous }
        let providers = Set((user.identities ?? []).map(\.provider))
        if providers.contains("apple") { return .apple }
        if let email = user.email, !email.isEmpty { return .email(email) }
        return .other
    }

    private static func appleSubject(_ identity: UserIdentity) -> String {
        identity.identityData?["sub"]?.stringValue ?? identity.id
    }

    // MARK: - Signing in

    /// Signs in with Apple's ID token, or adds Apple to an account made
    /// before sign-in existed, which keeps that account and everything in it.
    ///
    /// - Parameter nonce: the raw value whose SHA-256 went into Apple's
    ///   request. Supabase checks the token carries it.
    func signInWithApple(idToken: String, nonce: String) async throws {
        try await establish { client, addsToAccount in
            let credentials = OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce)
            return addsToAccount
                ? try await client.auth.linkIdentityWithIdToken(credentials: credentials)
                : try await client.auth.signInWithIdToken(credentials: credentials)
        }
    }

    /// Signs in with the same Apple ID token, leaving behind an account made
    /// before sign-in existed. For when that Apple ID turned out to have its
    /// own account already, and the student chose it.
    func switchToApple(idToken: String, nonce: String) async throws {
        try await establish(replacingAnonymous: true) { client, _ in
            try await client.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(provider: .apple, idToken: idToken, nonce: nonce))
        }
    }

    /// Sends a 6-digit code to `email`. Signing in with it makes the account
    /// if there isn't one. For an account made before sign-in existed, the
    /// code instead confirms the address being added to it.
    ///
    /// - Parameter captchaToken: the Turnstile pass, required by the server
    ///   once CAPTCHA is on. Ignored when adding an address, which the server
    ///   does not check.
    func sendEmailCode(to email: String, captchaToken: String?,
                       replacingAnonymous: Bool = false) async throws {
        guard let client else { throw SignInError.unavailable }
        guard let address = EmailAddress.normalized(email) else { throw SignInError.invalidEmail }
        let addsToAccount = !replacingAnonymous && isAnonymousSignedIn
        do {
            if addsToAccount {
                try await client.auth.update(user: UserAttributes(email: address))
            } else {
                try await client.auth.signInWithOTP(email: address, shouldCreateUser: true,
                                                    captchaToken: captchaToken)
            }
            pendingEmail = (address, addsToAccount)
        } catch {
            throw SignInError.from(error)
        }
    }

    /// Checks the code `sendEmailCode` sent, and signs in with it.
    func verifyEmailCode(_ code: String) async throws {
        guard let pending = pendingEmail else { throw SignInError.codeRejected }
        let token = code.filter(\.isNumber)
        guard token.count == 6 else { throw SignInError.codeRejected }
        try await establish(replacingAnonymous: !pending.addsToAccount) { client, _ in
            let response = try await client.auth.verifyOTP(
                email: pending.address, token: token,
                type: pending.addsToAccount ? .emailChange : .email)
            if case .session(let session) = response { return session }
            // Confirming an added address can answer with the user alone; the
            // session is the same one, renewed so it carries the address.
            return try await client.auth.refreshSession()
        }
        pendingEmail = nil
    }

    private var isAnonymousSignedIn: Bool {
        if case .signedIn(_, true) = state { return true }
        return false
    }

    /// The checks every sign-in shares, around the request that signs in.
    ///
    /// The storage checks are the ones anonymous creation had: the SDK can
    /// swallow a failed Keychain write and report success, which would leave
    /// the student signed in for this launch only and lose the account at the
    /// next. A sign-in that did not land in storage is not a sign-in.
    ///
    /// - Parameters:
    ///   - replacingAnonymous: sign in to another account even though an
    ///     anonymous one is signed in here, instead of adding to it.
    ///   - obtain: the request. Its second argument says whether it should
    ///     add the new way in to the anonymous account signed in now.
    private func establish(replacingAnonymous: Bool = false,
                           _ obtain: (SupabaseClient, _ addsToAccount: Bool) async throws -> Session) async throws {
        guard let client else { throw SignInError.unavailable }
        if case .signedIn(_, false) = state { return }
        let addsToAccount = !replacingAnonymous && isAnonymousSignedIn
        do {
            try storage.beginAttempt()
            try storage.checkWritable()
            try storage.checkHealth()
            let session = try await obtain(client, addsToAccount)
            try storage.checkHealth()
            guard client.auth.currentSession?.user.id == session.user.id else {
                throw SessionStorageUnavailable()
            }
            try storage.checkHealth()
            credentialRejected = false
            awaitingRenewal = false
            arrival = .signedIn
            adopt(session.user)
        } catch {
            throw SignInError.from(error)
        }
    }

    /// Signs out on this phone only. Never for an anonymous account, which
    /// has no way back in: the screens offer saving it instead.
    func signOut() async throws {
        guard signInMethod != .anonymous else { throw SignInError.other }
        try storage.beginAttempt()
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                // The SDK clears local credentials before its logout request;
                // a phone that cannot reach the server is still signed out.
                guard client.auth.currentSession == nil else { throw error }
            }
        }
        try storage.checkHealth()
        try storage.clearRecovery()
        awaitingRenewal = false
        signedOut(as: .needsAccount)
    }

    /// Stops counting the account's tasks on the server as active, because
    /// they are not on this phone: after signing in on a new phone, or after
    /// another account's tasks were removed from this one. The free plan caps
    /// active tasks on the server, and without this a student could be at
    /// "5 of 5" with nothing on screen.
    func releaseServerTasks() async throws {
        guard let client else { throw Backend.ConfigError.missing("Supabase") }
        try await Self.release(client, storage: storage)
    }

    private nonisolated static func release(_ client: SupabaseClient, storage: ResilientAuthStorage) async throws {
        _ = try await validatedSession(client, storage: storage)
        try await client.rpc("release_my_active_assignments").execute()
    }

    /// Asks the server something that changes nothing, before anything that
    /// could delete the account is sent: with no signal this fails, and
    /// nothing has left the phone.
    ///
    /// Never renews a pass still in date. A renewal the server refused would
    /// make the SDK drop the pass, though the deletion itself could still have
    /// used it, and the phone would be cleared as if the account had gone
    /// while it stayed on the server. An expired pass is renewed, as for any
    /// request, and one refused then throws `AccountUnreachable`, as ever.
    func reachServer() async throws {
        guard let client else { throw Backend.ConfigError.missing("Supabase") }
        try storage.beginAttempt()
        // As below: probe storage first, so a failed read cannot pass for an
        // absent session.
        _ = client.auth.currentSession
        try storage.checkHealth()
        try await Self.readNothing(client, storage: storage)
    }

    /// One of the student's own assignments, which row security limits the
    /// read to, fetched and thrown away. Outside the main actor for the reason
    /// `requestDeletion` gives.
    private nonisolated static func readNothing(_ client: SupabaseClient, storage: ResilientAuthStorage) async throws {
        _ = try await validatedSession(client, storage: storage)
        try await client.from("assignments").select("id").limit(1).execute()
        try storage.checkHealth()
    }

    /// - Parameter appleAuthorizationCode: a fresh code from Apple, needed
    ///   when the account uses Sign in with Apple: the server trades it for a
    ///   token and revokes that, as Apple requires on deletion.
    func deleteRemoteAccount(appleAuthorizationCode: String? = nil) async throws {
        guard let client else { throw Backend.ConfigError.missing("Supabase") }
        try storage.beginAttempt()
        // The SDK may turn a failed storage read into an absent session. Probe
        // it before entering the request so that absence cannot confirm deletion.
        _ = client.auth.currentSession
        try storage.checkHealth()
        try await Self.requestDeletion(client, storage: storage, appleAuthorizationCode: appleAuthorizationCode)
    }

    /// The request, outside the main actor for the reason `PlanReader` gives:
    /// a response that is not Sendable must not cross an isolation boundary,
    /// which Xcode 16.4 rejects and Xcode 26 allows. Here the response is
    /// consumed where it is produced, and only success or an error comes back.
    private nonisolated static func requestDeletion(_ client: SupabaseClient, storage: ResilientAuthStorage,
                                                    appleAuthorizationCode: String?) async throws {
        // Resolve credentials explicitly so a temporary refresh failure cannot
        // become proof of loss.
        _ = try await validatedSession(client, storage: storage)
        do {
            try await client.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(body: DeletionRequest(appleAuthorizationCode: appleAuthorizationCode)))
        } catch FunctionsError.httpError(let status, let data) {
            // Each of these is the server saying it deleted nothing, so the
            // phone can say so too and keep everything.
            let code = (try? JSONDecoder().decode(DeletionRefusal.Body.self, from: data))?.error
            switch (status, code) {
            case (428, "APPLE_REAUTH_REQUIRED"): throw DeletionRefusal.needsApple
            case (400, "APPLE_CODE_INVALID"): throw DeletionRefusal.appleCodeInvalid
            case (400, "APPLE_ACCOUNT_MISMATCH"): throw DeletionRefusal.differentAppleID
            default: throw FunctionsError.httpError(code: status, data: data)
            }
        }
        try storage.checkHealth()
    }

    private struct DeletionRequest: Encodable, Sendable {
        let appleAuthorizationCode: String?
        enum CodingKeys: String, CodingKey { case appleAuthorizationCode = "apple_authorization_code" }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(appleAuthorizationCode, forKey: .appleAuthorizationCode)
        }
    }

    /// The session to act with, and whether the server renewed it to get it.
    ///
    /// - Parameter renew: ask the server even when the pass is still in date.
    private nonisolated static func validatedSession(_ client: SupabaseClient,
                                                     storage: ResilientAuthStorage,
                                                     renew: Bool = false) async throws -> (Session, renewed: Bool) {
        let current = client.auth.currentSession
        try storage.checkHealth()
        if !renew, let current, !current.isExpired { return (current, false) }
        guard let token = try current?.refreshToken ?? storage.recoveryRefreshToken() else {
            throw AuthError.sessionMissing
        }
        do {
            // A supplied credential distinguishes terminal server rejection from
            // the SDK's identical error for an ordinarily empty local store.
            let session = try await client.auth.refreshSession(refreshToken: token)
            try storage.checkHealth()
            return (session, true)
        } catch {
            try storage.checkHealth()
            if (error as? AuthError) == .sessionMissing { throw AccountUnreachable() }
            throw error
        }
    }

    func signOutDeletedAccount() async throws {
        try storage.beginAttempt()
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                // The SDK clears local credentials before its logout request.
                // A deleted account needs no successful second server round trip.
                guard client.auth.currentSession == nil else { throw error }
            }
        }
        try storage.checkHealth()
        try storage.clearRecovery()
        awaitingRenewal = false
        signedOut(as: .needsAccount)
    }

}

/// The server refused a deletion before deleting anything. Safe to tell the
/// student plainly, and nothing on the phone needs to change.
enum DeletionRefusal: Error, Equatable {
    /// The account uses Sign in with Apple and Apple has to confirm first.
    case needsApple
    /// Apple's code was too old or already used.
    case appleCodeInvalid
    /// Apple confirmed a different Apple ID from the account's.
    case differentAppleID

    struct Body: Decodable { let error: String }

    var message: String {
        switch self {
        case .needsApple: "To delete an account that uses Sign in with Apple, confirm with Apple first."
        case .appleCodeInvalid: "Apple couldn't confirm it's you. Try again."
        case .differentAppleID: "That Apple ID isn't the one this account uses. Try again with the Apple ID you sign in with."
        }
    }
}
