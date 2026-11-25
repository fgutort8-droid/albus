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
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Text(recovering ? "Finish deleting your account" : "Delete your account")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)

                if recovering {
                    Text("Albus needs to finish clearing this phone before you can start again.")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                } else {
                    Text("Your assignments, plans, saved rubrics and marks are deleted for good. "
                         + "Signing in again starts a new, empty account.")
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // The one thing deleting does not do, said where it cannot
                    // be missed: Apple bills a subscription, not Albus.
                    GlassCard {
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            Text("It doesn't cancel a subscription")
                                .font(Tokens.Typography.cardTitle)
                                .foregroundStyle(Tokens.Palette.ink)
                            Text("Apple keeps billing until you cancel in Settings → your name → Subscriptions.")
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Text("If Albus can't reach your account, only this phone is cleared. "
                         + "Payment and security records may be kept.")
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Privacy policy") { openURL(AppLinks.privacy) }
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Palette.accent)
                }

                if let message = deletion.errorMessage {
                    StatusBanner(tone: .error, message: message)
                }
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Tokens.Spacing.s) {
                if deletion.isBusy {
                    ProgressView("Deleting your account…")
                        .frame(height: 50)
                } else if recovering {
                    PrimaryButton(title: "Try again") { Task { await removeAccount() } }
                } else {
                    HoldToConfirmButton(title: "Hold to delete") { Task { await removeAccount() } }
                        .accessibilityIdentifier("confirmAccountDeletion")
                }
                if !recovering {
                    Button("Cancel") { dismiss() }
                        .font(Tokens.Typography.label)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .frame(height: 44)
                        .disabled(deletion.isBusy)
                }
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            .padding(.bottom, Tokens.Spacing.l)
        }
        .interactiveDismissDisabled(deletion.isBusy)
        .task {
            if recovering { await removeAccount() }
        }
    }

    /// Without Apple's sheet unless the server needs it
    /// (`AccountDeletion.deleteAskingAppleOnlyIfNeeded`). Recovering a
    /// deletion the server already made asks nothing of Apple.
    private func removeAccount() async {
        if recovering {
            _ = await attempt(appleCode: nil)
            return
        }
        _ = await deletion.deleteAskingAppleOnlyIfNeeded(
            attempt: { await attempt(appleCode: $0) },
            appleCode: { try await AppleConfirmation().authorizationCode() })
    }

    private func attempt(appleCode: String?) async -> Bool {
        await deletion.perform(
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
