import AuthenticationServices
import SwiftUI

/// The first screen: Sign in with Apple.
///
/// Students sign in before the set-up questions (the owner's decision, 2 Oct
/// 2026), and only with Apple (6 Oct 2026). From Settings the same screen
/// saves an account made before sign-in existed, by adding Apple to it
/// (`savingAccount`).
///
/// There is no CAPTCHA: GoTrue never checks one when an Apple ID token is
/// exchanged, and there is no other way in.
struct SignInScreen: View {
    var savingAccount = false

    @Environment(SessionService.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var message: String?
    @State private var isWorking = false
    @State private var nonce = AppleSignIn.makeNonce()
    /// Saving an account, and the Apple ID chosen turned out to have its own
    /// account. Offered as a switch.
    @State private var conflict: Conflict?

    private struct Conflict: Equatable {
        let token: String
        let nonce: String
    }

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(alignment: .leading, spacing: 0) {
                topBar
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                        header
                        appleButton
                        if let message {
                            StatusBanner(tone: .error, message: message)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.xl)
                    .padding(.top, Tokens.Spacing.l)
                    .padding(.bottom, Tokens.Spacing.xl)
                }

                if !savingAccount {
                    agreementFootnote
                        .padding(.horizontal, Tokens.Spacing.xl)
                        .padding(.bottom, Tokens.Spacing.l)
                }
            }
        }
        .confirmationDialog(SignInError.appleIDInUse.message ?? "", isPresented: conflictShown,
                            titleVisibility: .visible) {
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
            if savingAccount {
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
            AlbusCactus(size: 64, mood: .calm)
                .padding(.bottom, Tokens.Spacing.s)
                .accessibilityHidden(true)
            Text(savingAccount ? "Save your account." : "Welcome to Albus.")
                .font(Tokens.Typography.title)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(savingAccount
                 ? "Add Apple, so you can sign back in if you change phones."
                 : "Sign in to start planning.")
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var appleButton: some View {
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

            if isWorking { ProgressView().padding(.top, Tokens.Spacing.s) }
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
                    conflict = Conflict(token: token, nonce: nonce)
                } else {
                    message = failure.message
                }
            }
        }
    }

    // MARK: - Saving an account whose Apple ID is taken

    private var conflictShown: Binding<Bool> {
        Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } })
    }

    private func switchAccounts() {
        guard let chosen = conflict else { return }
        conflict = nil
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                try await session.switchToApple(idToken: chosen.token, nonce: chosen.nonce)
                dismiss()
            } catch {
                message = SignInError.from(error).message
            }
        }
    }

    // MARK: - Agreement

    /// Beside the buttons that make the account, so the age rule and the
    /// terms are in front of the student before there is one. The sentence
    /// ends in the two documents, on the line below.
    static let agreement = "By continuing, you confirm you're 13 or older, with a parent's or "
        + "guardian's agreement if you're under 16, and you accept"

    /// The documents are buttons, as in Settings, not links inside the
    /// sentence: iOS 18 does not expose a sentence's links as separate
    /// controls, so on GitHub's simulators the UI test that proves each one
    /// opens the right page could not find them.
    private var agreementFootnote: some View {
        let terms = Button("Terms of service") { openURL(AppLinks.terms) }
            .foregroundStyle(Tokens.Palette.accent)
        let privacy = Button("Privacy policy") { openURL(AppLinks.privacy) }
            .foregroundStyle(Tokens.Palette.accent)
        return VStack(alignment: .leading, spacing: 2) {
            Text(Self.agreement)
                .fixedSize(horizontal: false, vertical: true)
            // The sentence ends here. At large text sizes this line breaks in
            // two, and still reads as the end of the sentence.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 0) {
                    Text("the ")
                    terms
                    Text(" and ")
                    privacy
                    Text(".")
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 0) {
                        Text("the ")
                        terms
                        Text(" and")
                    }
                    HStack(spacing: 0) {
                        privacy
                        Text(".")
                    }
                }
            }
            .buttonStyle(.plain)
        }
        .font(Tokens.Typography.caption)
        .foregroundStyle(Tokens.Palette.inkSecondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
