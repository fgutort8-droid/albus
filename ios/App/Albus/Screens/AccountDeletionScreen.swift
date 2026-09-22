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
    @State private var confirmation = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(recovering ? "Finish deleting your account" : "Delete account")
                    .font(Tokens.Typography.cardTitle)
                if recovering {
                    Text("Your account is deleted. Albus needs to finish clearing this phone before you can start again.")
                } else {
                    Text("Your account, assignments, saved rubrics and marks will be deleted. This can't be undone.")
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

    private func removeAccount() async {
        _ = await deletion.perform(
            deleteRemote: { try await session.deleteRemoteAccount() },
            clearLocal: {
                coordinator.invalidateForAccountDeletion()
                focus.cancel(context: context)
                await notifications.clearForAccountDeletion()
                try AccountLocalData.erase(context: context, preferences: preferences)
            },
            signOut: { try await session.signOutDeletedAccount() }
        )
    }
}
