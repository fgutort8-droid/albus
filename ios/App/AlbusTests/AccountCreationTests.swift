import Foundation
import Testing
@testable import Albus

/// The rule the CAPTCHA exists for, tested where onboarding enforces it: with
/// it switched on, no account is created without a pass.
@MainActor
@Suite("Account creation and the CAPTCHA")
struct AccountCreationTests {

    /// Stands in for the sign-up request and records what each call carried.
    @MainActor
    private final class SignUpRecorder {
        var passes: [String?] = []
        var succeeds = true

        func signUp(_ pass: String?) async -> Bool {
            passes.append(pass)
            return succeeds
        }
    }

    private func creation(captcha: Bool = true,
                          signedIn: Bool = false,
                          prefetch: CaptchaPrefetch,
                          recorder: SignUpRecorder) -> AccountCreation {
        AccountCreation(captchaEnabled: captcha,
                        isSignedIn: { signedIn },
                        prefetch: prefetch,
                        signUp: { await recorder.signUp($0) },
                        passWait: .milliseconds(150))
    }

    @Test("with the CAPTCHA on, a failed quiet check leads to the visible check, not a sign-up")
    func failedCheckNeverSignsUp() async {
        let prefetch = CaptchaPrefetch()
        prefetch.failed(generation: 0)
        let recorder = SignUpRecorder()

        #expect(await creation(prefetch: prefetch, recorder: recorder).start() == .needsVisibleCheck)
        #expect(recorder.passes.isEmpty)
    }

    @Test("with the CAPTCHA on, a check that wants a person leads to the visible check, not a sign-up")
    func interactiveCheckNeverSignsUp() async {
        let prefetch = CaptchaPrefetch()
        prefetch.needsPerson(generation: 0)
        let recorder = SignUpRecorder()

        #expect(await creation(prefetch: prefetch, recorder: recorder).start() == .needsVisibleCheck)
        #expect(recorder.passes.isEmpty)
    }

    @Test("with the CAPTCHA on, a quiet check that never answers leads to the visible check, not a sign-up")
    func silentCheckNeverSignsUp() async {
        let prefetch = CaptchaPrefetch()
        let recorder = SignUpRecorder()

        #expect(await creation(prefetch: prefetch, recorder: recorder).start() == .needsVisibleCheck)
        #expect(recorder.passes.isEmpty)
    }

    @Test("the prefetched pass is what the sign-up sends")
    func prefetchedPassReachesSignUp() async {
        let prefetch = CaptchaPrefetch()
        prefetch.received(token: "pass-1", generation: 0)
        let recorder = SignUpRecorder()

        #expect(await creation(prefetch: prefetch, recorder: recorder).start() == .created)
        #expect(recorder.passes == ["pass-1"])
    }

    @Test("a pass that went to a failed sign-up is never sent again")
    func spentPassIsNeverResent() async {
        let prefetch = CaptchaPrefetch()
        prefetch.received(token: "pass-1", generation: 0)
        let recorder = SignUpRecorder()
        recorder.succeeds = false
        let flow = creation(prefetch: prefetch, recorder: recorder)

        #expect(await flow.start() == .signUpFailed)
        // The retry finds no fresh pass in time, so it goes to the visible check.
        #expect(await flow.start() == .needsVisibleCheck)
        #expect(recorder.passes == ["pass-1"])
    }

    @Test("a failed sign-up starts fetching the next pass straight away")
    func failedSignUpFetchesNextPass() async {
        let prefetch = CaptchaPrefetch()
        prefetch.received(token: "pass-1", generation: 0)
        let recorder = SignUpRecorder()
        recorder.succeeds = false

        #expect(await creation(prefetch: prefetch, recorder: recorder).start() == .signUpFailed)
        #expect(prefetch.state == .fetching)
        #expect(prefetch.generation == 1)
    }

    @Test("a visible check that ends without a pass creates nothing")
    func incompleteVisibleCheckCreatesNothing() async {
        let recorder = SignUpRecorder()
        let flow = creation(prefetch: CaptchaPrefetch(), recorder: recorder)

        #expect(await flow.finishVisibleCheck(pass: nil) == .checkIncomplete)
        #expect(recorder.passes.isEmpty)
    }

    @Test("the visible check's pass is what the sign-up sends")
    func visibleCheckPassReachesSignUp() async {
        let recorder = SignUpRecorder()
        let flow = creation(prefetch: CaptchaPrefetch(), recorder: recorder)

        #expect(await flow.finishVisibleCheck(pass: "pass-2") == .created)
        #expect(recorder.passes == ["pass-2"])
    }

    @Test("with the CAPTCHA off, sign-up goes ahead without a pass, as before")
    func captchaOffSignsUpWithoutPass() async {
        let recorder = SignUpRecorder()
        let flow = creation(captcha: false, prefetch: CaptchaPrefetch(), recorder: recorder)

        #expect(await flow.start() == .created)
        #expect(recorder.passes == [nil])
    }

    @Test("an existing account is never created again")
    func existingAccountIsNotRecreated() async {
        let prefetch = CaptchaPrefetch()
        prefetch.received(token: "pass-1", generation: 0)
        let recorder = SignUpRecorder()
        let flow = creation(signedIn: true, prefetch: prefetch, recorder: recorder)

        #expect(await flow.start() == .created)
        #expect(await flow.finishVisibleCheck(pass: nil) == .created)
        #expect(recorder.passes.isEmpty)
        #expect(prefetch.state == .ready, "the pass is left unused")
    }

    /// The account is made on the sign-in screen, so the age rule and the
    /// terms are stated there. The sentence ends in the two pages, which are
    /// buttons; `LegalLinkDestinationsUITests` checks where each one goes.
    @Test func signInStatesTheTermsAndAge() {
        let text = SignInScreen.agreement
        #expect(text.contains("13 or older"))
        #expect(text.contains("under 16"))
        #expect(text.hasSuffix("you accept"))
    }
}
