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

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

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
    func start() async {
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
        do {
            try storage.beginAttempt()
            let session = try await client.auth.session
            try storage.checkHealth()
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
        } catch {
            // No stored session, or it could not be refreshed. Which of those
            // it was matters to `AccountDeletion`: a refused credential is the
            // only evidence a phone has that a deletion it never heard back
            // about actually happened.
            guard (try? storage.checkHealth()) != nil else {
                state = .failed(SessionStorageUnavailable().localizedDescription)
                return
            }
            credentialRejected = !(error is URLError)
            state = .needsAccount
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
            if let existing = client.auth.currentSession {
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
            state = .failed(Self.describe(error))
            return false
        }
    }

    func deleteRemoteAccount() async throws {
        guard let client else { throw Backend.ConfigError.missing("Supabase") }
        try storage.checkHealth()
        try await Self.requestDeletion(client, storage: storage)
    }

    /// The request, outside the main actor for the reason `PlanReader` gives:
    /// `PostgrestResponse` is not Sendable, so awaiting `execute()` from this
    /// actor-isolated class sends it across an isolation boundary, which
    /// Xcode 16.4 rejects and Xcode 26 allows. Here the response is consumed
    /// where it is produced, and only success or an error comes back.
    private nonisolated static func requestDeletion(_ client: SupabaseClient, storage: ResilientAuthStorage) async throws {
        do {
            try await client.rpc("delete_my_account").execute()
        } catch {
            let unreachable = isUnreachable(error, client: client)
            try storage.checkHealth()
            guard unreachable else { throw error }
            throw AccountUnreachable()
        }
    }

    /// Whether this failure means the account can no longer be reached from
    /// this device.
    ///
    /// The case this exists for: the delete committed on the server and the
    /// answer was lost. The student retries an hour later, by which time the
    /// access token has expired and the refresh token died with the account,
    /// so every attempt from here on is refused — and without this, the app
    /// asks them to try again forever while their work stays on the phone.
    ///
    /// A network failure is never evidence: it is the ordinary way a phone
    /// fails, and reading it as "deleted" would erase the work of anyone who
    /// tapped Delete in a lift and changed their mind.
    private nonisolated static func isUnreachable(_ error: Error, client: SupabaseClient) -> Bool {
        if error is URLError { return false }
        // Strongest signal: the SDK abandons a stored session only once the
        // server has definitively refused it.
        if client.auth.currentSession == nil { return true }
        if let postgrest = error as? PostgrestError {
            // 28000 is `delete_my_account`'s own NOT_SIGNED_IN; PostgREST's
            // PGRST3xx group is every JWT rejection.
            return postgrest.code == "28000" || postgrest.code?.hasPrefix("PGRST3") == true
        }
        return error is AuthError
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
        state = .needsAccount
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No connection."
        }
        return error.localizedDescription
    }
}
