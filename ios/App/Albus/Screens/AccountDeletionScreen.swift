import SwiftUI
import SwiftData

struct AccountDeletionScreen: View {
    var recovering = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AccountDeletion.self) private var deletion
    @Environment(SessionService.self) private var session
    @Environment(Preferences.self) private var preferences
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(FocusSession.self) private var focus
    @Environment(NotificationCoordinator.self) private var notifications
    @Environment(LocalAccount.self) private var localAccount
    @State private var confirmation = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(recovering ? "Finish deleting your account" : "Delete account")
                    .font(Tokens.Typography.cardTitle)
                if recovering {
                    Text("Your account is deleted. Albus needs to finish clearing this phone before you can start again.")
                } else {
                    Text("Your account, assignments, saved rubrics and marks will be deleted. This can't be undone. Signing in again afterwards starts a new, empty account.")
                    if needsApple {
                        Text("Apple will ask you to confirm it's you, so Albus can also stop using your Sign in with Apple.")
                    }
                    Text("Deleting your account does NOT cancel an Apple subscription. Apple will keep billing you until you cancel in iPhone Settings → your name → Subscriptions.")
                        .fontWeight(.semibold)
                    TextField("Type DELETE to confirm", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("accountDeletionConfirmation")
                }
                if let message = deletion.errorMessage {
                    Text(message).foregroundStyle(Tokens.Palette.danger)
                }
                if deletion.isBusy { ProgressView("Deleting account…") }
                Button(recovering ? "Try again" : "Permanently delete account", role: .destructive) {
                    Task { await removeAccount() }
                }
                .disabled(deletion.isBusy || (!recovering && confirmation != "DELETE"))
                .accessibilityIdentifier("confirmAccountDeletion")
                if !recovering {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .disabled(deletion.isBusy)
                }
            }
            .padding(Tokens.Spacing.xl)
            .foregroundStyle(Tokens.Palette.ink)
        }
        .interactiveDismissDisabled(deletion.isBusy)
        .task {
            if recovering { await removeAccount() }
        }
    }

    /// An account that uses Sign in with Apple, or one the server said does.
    /// Apple has to confirm before the server will delete it: see
    /// `AppleConfirmation`.
    private var needsApple: Bool {
        session.signInMethod == .apple || deletion.refused != nil
    }

    private func removeAccount() async {
        var appleCode: String?
        if !recovering, !deletion.requiresCleanup, needsApple {
            do {
                appleCode = try await AppleConfirmation().authorizationCode()
            } catch {
                deletion.errorMessage = SignInError.from(error) == .cancelled
                    ? DeletionRefusal.needsApple.message
                    : DeletionRefusal.appleCodeInvalid.message
                return
            }
        }
        _ = await deletion.perform(
            reachServer: { try await session.reachServer() },
            deleteRemote: { try await session.deleteRemoteAccount(appleAuthorizationCode: appleCode) },
            clearLocal: {
                coordinator.invalidateForAccountDeletion()
                focus.cancel(context: context)
                await notifications.clearForAccountDeletion()
                try AccountLocalData.erase(context: context, preferences: preferences)
                localAccount.forget()
            },
            signOut: { try await session.signOutDeletedAccount() }
        )
    }
}
