import AuthenticationServices
import SwiftUI

/// The first screen: sign in with Apple, or with a 6-digit code sent by email.
///
/// Students sign in before the set-up questions (the owner's decision, 2 Oct
/// 2026). From Settings the same screen saves an account made before sign-in
/// existed, by adding Apple or an email to it (`savingAccount`).
///
/// The CAPTCHA covers the email route only. GoTrue never checks one when an
/// Apple ID token is exchanged, and Apple IDs are costly to make in bulk; an
/// email address is not, so the code request carries a Turnstile pass once
/// CAPTCHA is on.
struct SignInScreen: View {
    var savingAccount = false

    @Environment(SessionService.self) private var session
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable { case choose, email, code }
    @State private var step: Step = .choose
    @State private var email = ""
    @State private var code = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var nonce = AppleSignIn.makeNonce()
    @State private var resendAt = Date.distantPast
    /// Saving an account, and the Apple ID or email chosen turned out to have
    /// its own account. Offered as a switch.
    @State private var conflict: Conflict?
    /// Saving an account, and the student chose to sign in to the email's own
    /// account instead.
    @State private var switching = false

    /// The CAPTCHA pass, fetched while the student types their address.
    @State private var prefetch = CaptchaPrefetch()
    @State private var showingCaptcha = false
    @State private var lastError: SignInError?

    private enum Conflict: Equatable {
        case apple(token: String, nonce: String)
        case email
    }

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                        header
                        switch step {
                        case .choose: choices
                        case .email: emailEntry
                        case .code: codeEntry
                        }
                        if let message {
                            StatusBanner(tone: .error, message: message)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .padding(.top, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)

                if !savingAccount, step != .code {
                    Text(Self.agreement)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .tint(Tokens.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Tokens.Spacing.xl)
                        .padding(.bottom, Tokens.Spacing.l)
                        .accessibilityIdentifier("signIn.agreement")
                }
            }
        }
        .background {
            // Behind the opaque background, as in onboarding before this
            // screen existed. See `CaptchaPrefetchPage`.
            if prefetchRuns {
                CaptchaPrefetchPage(prefetch: prefetch, generation: prefetch.generation)
                    .frame(width: 320, height: 120)
                    .opacity(0.01)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onDisappear { prefetch.stop() }
        .animation(Tokens.Motion.sheet, value: step)
        .sheet(isPresented: $showingCaptcha) {
            CaptchaSheet { token in
                showingCaptcha = false
                Task {
                    isWorking = true
                    handle(await codeRequest.finishVisibleCheck(pass: token))
                    isWorking = false
                }
            }
            .presentationDetents([.height(320)])
        }
        .confirmationDialog(conflictTitle, isPresented: conflictShown, titleVisibility: .visible) {
            Button("Sign in to that account", role: .destructive) { switchAccounts() }
            Button("Cancel", role: .cancel) { conflict = nil }
        } message: {
            Text("The account on this phone hasn't been saved, so you won't be able to get back to it, and its tasks will be removed from this phone.")
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private var topBar: some View {
        HStack {
            if step != .choose {
                IconButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    message = nil
                    step = step == .code ? .email : .choose
                }
            } else if savingAccount {
                IconButton(systemImage: "xmark", accessibilityLabel: "Close") { dismiss() }
            }
            Spacer()
        }
        .frame(height: 44)
        .padding(.horizontal, Tokens.Spacing.xl)
        .padding(.top, Tokens.Spacing.s)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            if step == .choose {
                AlbusCactus(size: 64, mood: .calm)
                    .padding(.bottom, Tokens.Spacing.s)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var title: String {
        switch step {
        case .choose: savingAccount ? "Save your account." : "Welcome to Albus."
        case .email: "Sign in with email."
        case .code: "Check your email."
        }
    }

    private var subtitle: String {
        switch step {
        case .choose:
            savingAccount
                ? "Add Apple or an email, so you can sign back in if you change phones."
                : "Sign in to start planning."
        case .email: "We'll send you a 6-digit code. No password needed."
        case .code: "Enter the code we sent to \(EmailAddress.normalized(email) ?? email)."
        }
    }

    private var choices: some View {
        VStack(spacing: Tokens.Spacing.m) {
            SignInWithAppleButton(.continue) { request in
                // A new one per attempt; the token Apple returns carries its hash.
                let fresh = AppleSignIn.makeNonce()
                nonce = fresh
                request.requestedScopes = [.email]
                request.nonce = AppleSignIn.sha256(fresh)
            } onCompletion: { result in
                switch result {
                case .success(let authorization):
                    guard let token = AppleSignIn.identityToken(from: authorization) else {
                        message = SignInError.other.message
                        return
                    }
                    signInWithApple(token: token, nonce: nonce)
                case .failure(let error):
                    message = SignInError.from(error).message
                }
            }
            .signInWithAppleButtonStyle(.black)
            .frame(height: 50)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
            .disabled(isWorking)
            .accessibilityIdentifier("signIn.apple")

            Button {
                message = nil
                step = .email
            } label: {
                // Sized to match the Apple button beside it, which sets its
                // own type from its height.
                Label("Continue with email", systemImage: "envelope")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Tokens.Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Tokens.Glass.fill,
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                            .strokeBorder(Tokens.Palette.hairline, lineWidth: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isWorking)
            .accessibilityIdentifier("signIn.email")

            if isWorking { ProgressView().padding(.top, Tokens.Spacing.s) }
        }
    }

    private var emailEntry: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            field("Your email") {
                // Verbatim, or the example is styled as a link and reads as
                // something already typed.
                TextField(text: $email, prompt: Text(verbatim: "e.g. alex@example.com")) {
                    Text("Your email")
                }
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit(sendCode)
                    .padding(Tokens.Spacing.m)
                    .background(Tokens.Glass.fill,
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                            .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                    }
                    .accessibilityIdentifier("signIn.emailField")
            }
            PrimaryButton(title: isWorking ? "Sending…" : "Send code",
                          isEnabled: !isWorking && EmailAddress.normalized(email) != nil,
                          action: sendCode)
                .accessibilityIdentifier("signIn.sendCode")
        }
    }

    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
            field("6-digit code") {
                // The check starts from the binding, with the six digits that
                // completed it, rather than from an `onChange` reading state
                // back: a code typed in one go was once left sitting there.
                TextField("123456", text: Binding(get: { code }, set: { typed in
                    let digits = String(typed.filter(\.isNumber).prefix(6))
                    code = digits
                    if digits.count == 6 { verify(digits) }
                }))
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .padding(Tokens.Spacing.m)
                    .background(Tokens.Glass.fill,
                                in: RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Tokens.Radius.control, style: .continuous)
                            .strokeBorder(Tokens.Palette.hairline, lineWidth: 0.5)
                    }
                    .accessibilityIdentifier("signIn.codeField")
            }
            PrimaryButton(title: isWorking ? "Checking…" : "Continue",
                          isEnabled: !isWorking && code.count == 6) { verify(code) }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let wait = Int(resendAt.timeIntervalSince(context.date).rounded(.up))
                Button(wait > 0 ? "Send a new code in \(wait)s" : "Send a new code", action: sendCode)
                    .font(Tokens.Typography.label)
                    .foregroundStyle(wait > 0 || isWorking ? Tokens.Palette.inkMuted : Tokens.Palette.accent)
                    .disabled(wait > 0 || isWorking)
            }
            Text("It can take a minute to arrive. Check your spam folder too.")
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkMuted)
        }
    }

    private func field<Content: View>(_ label: String,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(label.uppercased())
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(Tokens.Palette.inkMuted)
            content()
        }
    }

    // MARK: - Apple

    private func signInWithApple(token: String, nonce: String) {
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.signInWithApple(idToken: token, nonce: nonce)
                if savingAccount { dismiss() }
            } catch {
                let failure = SignInError.from(error)
                if savingAccount, failure == .appleIDInUse {
                    conflict = .apple(token: token, nonce: nonce)
                } else {
                    message = failure.message
                }
            }
        }
    }

    // MARK: - Email

    /// A code request goes through the same gate account creation did before
    /// sign-in existed: with CAPTCHA on, only with a pass. Adding an address
    /// to an anonymous account is not checked by the server, so it needs none.
    private var codeRequest: AccountCreation {
        AccountCreation(
            captchaEnabled: needsCaptcha,
            isSignedIn: { false },
            prefetch: prefetch,
            signUp: { pass in await requestCode(pass: pass) }
        )
    }

    private var needsCaptcha: Bool {
        Captcha.isEnabled && (!savingAccount || switching)
    }

    private var prefetchRuns: Bool {
        needsCaptcha && step != .choose && prefetch.state == .fetching
    }

    private func sendCode() {
        guard !isWorking else { return }
        guard EmailAddress.normalized(email) != nil else {
            message = SignInError.invalidEmail.message
            return
        }
        message = nil
        isWorking = true
        Task {
            handle(await codeRequest.start())
            isWorking = false
        }
    }

    private func requestCode(pass: String?) async -> Bool {
        do {
            try await session.sendEmailCode(to: email, captchaToken: pass, replacingAnonymous: switching)
            lastError = nil
            return true
        } catch {
            lastError = SignInError.from(error)
            return false
        }
    }

    private func handle(_ outcome: AccountCreation.Outcome) {
        switch outcome {
        case .created:
            code = ""
            resendAt = .now.addingTimeInterval(60)
            step = .code
        case .needsVisibleCheck:
            showingCaptcha = true
        case .checkIncomplete:
            message = "That check didn't complete. Try once more."
        case .signUpFailed:
            if savingAccount, !switching, lastError == .emailInUse {
                conflict = .email
            } else {
                message = (lastError ?? .other).message
            }
        }
    }

    private func verify(_ digits: String) {
        guard digits.count == 6, !isWorking else { return }
        message = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.verifyEmailCode(digits)
                if savingAccount { dismiss() }
            } catch {
                code = ""
                message = SignInError.from(error).message
            }
        }
    }

    // MARK: - Saving an account whose Apple ID or email is taken

    private var conflictShown: Binding<Bool> {
        Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })
    }

    private var conflictTitle: String {
        switch conflict {
        case .apple: SignInError.appleIDInUse.message ?? ""
        case .email: SignInError.emailInUse.message ?? ""
        case nil: ""
        }
    }

    private func switchAccounts() {
        guard let chosen = conflict else { return }
        conflict = nil
        switch chosen {
        case .apple(let token, let nonce):
            isWorking = true
            Task {
                defer { isWorking = false }
                do {
                    try await session.switchToApple(idToken: token, nonce: nonce)
                    dismiss()
                } catch {
                    message = SignInError.from(error).message
                }
            }
        case .email:
            switching = true
            sendCode()
        }
    }

    // MARK: - Agreement

    /// Beside the buttons that make the account, so the age rule and the
    /// terms are in front of the student before there is one.
    static var agreement: AttributedString {
        let text = "By continuing, you confirm you're 13 or older, with a parent's or "
            + "guardian's agreement if you're under 16, and you accept the "
            + "[Terms of service](\(AppLinks.terms.absoluteString)) and "
            + "[Privacy policy](\(AppLinks.privacy.absoluteString))."
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
