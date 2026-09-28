import Foundation
import Supabase

/// The account cannot be reached from this device any more.
///
/// Thrown instead of the underlying rejection so the deletion flow can stay
/// free of SDK error types, and so the one case that means "already gone"
/// cannot be confused with the several that mean "try again later".
struct AccountUnreachable: Error {}

/// Gets the user signed in, silently, before anything else runs.
///
/// Albus has no sign-up screen: every user is anonymous from first launch.
/// That is a product decision (a signup wall is the single biggest thing that
/// kills apps like this) but it is also why the session must be durable — the
/// anonymous account *is* the account, and losing it loses their work and
/// resets their free quota.
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

    /// True while the account on screen came from this phone's storage and its
    /// expired pass has not been renewed yet, because the phone was offline or
    /// the server did not answer. `revalidate()` tries again.
    private(set) var awaitingRenewal = false

    /// A renewal is in flight. Keeps `revalidate()` from racing `start()`.
    private var renewing = false

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

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
    ///   unanswered. Its account may already be gone, so the app waits for the
    ///   server rather than show its plans or buy under it.
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
                isAnonymous: true
            )
            return
        }
#endif
        guard let client else {
            state = .failed("Not configured")
            return
        }
        credentialRejected = false
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
                state = .signedIn(userID: stored.user.id, isAnonymous: stored.user.isAnonymous)
                awaitingRenewal = true
            }
            shown = state
            let session = try await Self.validatedSession(client, storage: storage)
            // Settled some other way while the server answered, by a sign-out
            // after a deletion say: that stands.
            guard state == shown else { return }
            try storage.checkHealth()
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
            awaitingRenewal = false
        } catch {
            guard state == shown else { return }
            settle(restoreFailure: error)
        }
    }

    /// Renews a pass that `start()` could not, once the student is back in the
    /// app. A refused pass is handled exactly as at launch; a network failure
    /// changes nothing, and the next return to the app tries again.
    func revalidate() async {
        guard awaitingRenewal, !renewing, let client, case .signedIn = state else { return }
        let shown = state
        renewing = true
        defer { renewing = false }
        do {
            try storage.beginAttempt()
            let session = try await Self.validatedSession(client, storage: storage)
            // Signed out while this was in flight: the sign-out stands, and
            // an answer for the old pass must not bring the account back.
            guard state == shown else { return }
            try storage.checkHealth()
            state = .signedIn(userID: session.user.id, isAnonymous: session.user.isAnonymous)
            awaitingRenewal = false
        } catch {
            guard state == shown else { return }
            settle(restoreFailure: error)
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
            state = .failed(SessionStorageUnavailable().localizedDescription)
            return
        }
        if error is AccountUnreachable {
            awaitingRenewal = false
            credentialRejected = true
            state = .needsAccount
        } else if (error as? AuthError) == .sessionMissing {
            // No credential was available; absence alone proves no deletion.
            awaitingRenewal = false
            state = .needsAccount
        } else if awaitingRenewal {
            // The network failed, not the account. The student keeps their
            // plans, anything that needs the server fails the way it does
            // offline, and `revalidate()` tries again. Never read as a
            // deletion: a phone in a tunnel proves nothing.
        } else {
            state = .failed("Couldn't restore your sign-in. Please try again.")
        }
    }

    /// Creates the anonymous account, carrying a CAPTCHA token when one is
    /// required.
    ///
    /// - Parameter captchaToken: must be non-nil whenever `Captcha.isEnabled`.
    ///   Passing nil in that case is a caller bug, and the server will reject
    ///   it — which is the correct outcome, not something to work around here.
    @discardableResult
    func createAccount(captchaToken: String? = nil) async -> Bool {
        guard let client else {
            state = .failed("Not configured")
            return false
        }

        // Never create a second account over a live one.
        if case .signedIn = state { return true }

        do {
            try storage.beginAttempt()
            try storage.checkWritable()
            // A retry after temporarily unavailable storage must restore first.
            let current = client.auth.currentSession
            let recoveryToken = try storage.recoveryRefreshToken()
            if current != nil || (recoveryToken != nil && state != .needsAccount) {
                try storage.checkHealth()
                let existing = try await Self.validatedSession(client, storage: storage)
                try storage.checkHealth()
                state = .signedIn(userID: existing.user.id, isAnonymous: existing.user.isAnonymous)
                return true
            }
            try storage.checkHealth()
            let session = try await client.auth.signInAnonymously(captchaToken: captchaToken)
            try storage.checkHealth()
            guard client.auth.currentSession?.user.id == session.user.id else {
                throw SessionStorageUnavailable()
            }
            try storage.checkHealth()
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
            return true
        } catch {
            if error is AccountUnreachable {
                credentialRejected = true
                state = .needsAccount
            } else {
                state = .failed(Self.describe(error))
            }
            return false
        }
    }

    func deleteRemoteAccount() async throws {
        guard let client else { throw Backend.ConfigError.missing("Supabase") }
        try storage.beginAttempt()
        // The SDK may turn a failed storage read into an absent session. Probe
        // it before entering the request so that absence cannot confirm deletion.
        _ = client.auth.currentSession
        try storage.checkHealth()
        try await Self.requestDeletion(client, storage: storage)
    }

    /// The request, outside the main actor for the reason `PlanReader` gives:
    /// `PostgrestResponse` is not Sendable, so awaiting `execute()` from this
    /// actor-isolated class sends it across an isolation boundary, which
    /// Xcode 16.4 rejects and Xcode 26 allows. Here the response is consumed
    /// where it is produced, and only success or an error comes back.
    private nonisolated static func requestDeletion(_ client: SupabaseClient, storage: ResilientAuthStorage) async throws {
        // The SDK's RPC adapter suppresses refresh errors. Resolve credentials
        // explicitly so a temporary refresh failure cannot become proof of loss.
        _ = try await validatedSession(client, storage: storage)
        try await client.rpc("delete_my_account").execute()
        try storage.checkHealth()
    }

    private nonisolated static func validatedSession(_ client: SupabaseClient,
                                                     storage: ResilientAuthStorage) async throws -> Session {
        let current = client.auth.currentSession
        try storage.checkHealth()
        if let current, !current.isExpired { return current }
        guard let token = try current?.refreshToken ?? storage.recoveryRefreshToken() else {
            throw AuthError.sessionMissing
        }
        do {
            // A supplied credential distinguishes terminal server rejection from
            // the SDK's identical error for an ordinarily empty local store.
            let session = try await client.auth.refreshSession(refreshToken: token)
            try storage.checkHealth()
            return session
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
        state = .needsAccount
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No connection."
        }
        return error.localizedDescription
    }
}
