import Foundation

/// Where onboarding creates the account, apart from its screens.
///
/// It exists so the rule that matters can be tested where it is enforced:
/// with CAPTCHA on, an account is created only with a pass. A missing pass
/// leads to the visible check, and a visible check that ends without one
/// creates nothing. Signing up without a pass instead would defeat the
/// whole point of the challenge.
@MainActor
struct AccountCreation {
    enum Outcome: Equatable {
        /// The account exists, now or already. Go on to the first plan.
        case created
        /// Show the visible check. `finishVisibleCheck(pass:)` takes it from there.
        case needsVisibleCheck
        /// The visible check ended without a pass.
        case checkIncomplete
        /// The sign-up request failed.
        case signUpFailed
    }

    let captchaEnabled: Bool
    let isSignedIn: () -> Bool
    let prefetch: CaptchaPrefetch
    /// The sign-up request, carrying the pass when there is one.
    let signUp: (_ pass: String?) async -> Bool
    /// How long "Build my plan" waits for a pass that is still on its way.
    /// Longer than it sounds on purpose: a check already under way usually
    /// finishes sooner than the visible one, which would start from nothing.
    var passWait: Duration = .seconds(30)

    /// From "Build my plan", with the pass the quiet check fetched.
    func start() async -> Outcome {
        // A flow resumed after a crash, say: the account is already there.
        if isSignedIn() { return .created }
        guard captchaEnabled else { return await create(pass: nil) }
        // Usually the quiet check finished while the student was typing. If it
        // is still running, this waits for it rather than starting again.
        guard let pass = await prefetch.take(waitingUpTo: passWait) else {
            // Cloudflare wants a person, or the quiet check failed.
            return .needsVisibleCheck
        }
        return await create(pass: pass)
    }

    /// From the visible check. `pass` is nil when it did not complete.
    func finishVisibleCheck(pass: String?) async -> Outcome {
        if isSignedIn() { return .created }
        guard let pass else { return .checkIncomplete }
        return await create(pass: pass)
    }

    private func create(pass: String?) async -> Outcome {
        guard await signUp(pass) else {
            // A pass is good for one attempt. Fetch the next one now, so Retry
            // does not have to wait for it.
            if pass != nil { prefetch.renew() }
            return .signUpFailed
        }
        return .created
    }
}
