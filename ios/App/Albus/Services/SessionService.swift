import Foundation
import Supabase

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

    var userID: UUID? {
        if case .signedIn(let id, _) = state { return id }
        return nil
    }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
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
        do {
            let session = try await client.auth.session
            state = .signedIn(userID: session.user.id,
                              isAnonymous: session.user.isAnonymous)
        } catch {
            // No stored session, or it could not be refreshed.
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
            let session = try await client.auth.signInAnonymously(captchaToken: captchaToken)
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
        try await client.rpc("delete_my_account").execute()
    }

    func signOutDeletedAccount() async throws {
        if let client {
            do {
                try await client.auth.signOut(scope: .local)
            } catch {
                // The SDK clears local credentials before its logout request.
                // A deleted account needs no successful second server round trip.
                guard client.auth.currentSession == nil else { throw error }
            }
        }
        state = .needsAccount
    }

    private static func describe(_ error: Error) -> String {
        if let urlError = error as? URLError, urlError.code == .notConnectedToInternet {
            return "No connection."
        }
        return error.localizedDescription
    }
}
