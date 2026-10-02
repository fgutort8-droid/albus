import SwiftUI
import SwiftData

/// Someone signed in, and the tasks on this phone belong to another account.
///
/// Tasks live only on the phone, so removing them cannot be undone; the
/// student chooses. Going back signs this account out and leaves the tasks for
/// the account that made them.
struct AccountSwitchScreen: View {
    let userID: UUID

    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(LocalAccount.self) private var localAccount
    @Environment(Preferences.self) private var preferences
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(FocusSession.self) private var focus
    @Environment(NotificationCoordinator.self) private var notifications

    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        ZStack {
            BackgroundGradient()
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Spacer()
                Text("Tasks from another account")
                    .font(Tokens.Typography.title)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("The tasks, rubrics and markings on this phone were made with a different Albus account. To continue as \(who), they'll be removed from this phone. This can't be undone.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("To keep them, go back and sign in with the account that made them.")
                    .font(Tokens.Typography.body)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                if let message {
                    StatusBanner(tone: .error, message: message)
                }
                PrimaryButton(title: isWorking ? "Working…" : "Remove them and continue",
                              isEnabled: !isWorking) {
                    Task { await remove() }
                }
                .accessibilityIdentifier("accountSwitch.remove")
                Button("Go back") {
                    Task { await goBack() }
                }
                .font(Tokens.Typography.label)
                .foregroundStyle(Tokens.Palette.accent)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .disabled(isWorking)
                .accessibilityIdentifier("accountSwitch.back")
            }
            .padding(Tokens.Spacing.xl)
        }
    }

    private var who: String {
        switch session.signInMethod {
        case .email(let address): address
        case .apple: "your Apple account"
        default: "this account"
        }
    }

    private func remove() async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await localAccount.removeOtherAccountsData(for: userID) {
                coordinator.invalidateForAccountDeletion()
                focus.cancel(context: context)
                await notifications.clearForAccountDeletion()
                try AccountLocalData.erase(context: context, preferences: preferences)
            }
        } catch {
            message = "Couldn't clear this phone. Please try again."
            return
        }
        // The account's own tasks are not on this phone either. If this
        // fails it is tried again at the next launch.
        if (try? await session.releaseServerTasks()) != nil {
            localAccount.releaseFinished()
        }
    }

    private func goBack() async {
        guard !isWorking else { return }
        isWorking = true
        message = nil
        defer { isWorking = false }
        do {
            try await session.signOut()
            localAccount.signedOut()
        } catch {
            message = "Couldn't sign out. Please try again."
        }
    }
}
