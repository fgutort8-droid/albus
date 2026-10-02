import SwiftUI
import SwiftData
import AlbusCore

/// Chooses between signing in, the set-up questions and the app.
///
/// Signing in comes first (the owner's decision, 2 Oct 2026). The app opens
/// only for an account that has finished the set-up questions, and only once
/// the phone knows its data belongs to that account: a different account
/// signing in must never see the previous one's tasks, even for a frame.
struct RootView: View {
    @Environment(\.modelContext) private var context
    @Environment(SessionService.self) private var session
    @Environment(AccountDeletion.self) private var deletion
    @Environment(Preferences.self) private var preferences
    @Environment(PurchaseService.self) private var purchases
    @Environment(EntitlementService.self) private var entitlements
    @Environment(LocalAccount.self) private var localAccount
    @Environment(PlanCoordinator.self) private var coordinator
    @Environment(NotificationCoordinator.self) private var notifications

    var body: some View {
        Group {
            if deletion.requiresCleanup {
                AccountDeletionScreen(recovering: true)
            } else if let waiting = localAccount.awaitingDecision, waiting == session.userID {
                AccountSwitchScreen(userID: waiting)
            } else {
                switch session.state {
                case .starting:
                    LaunchPlaceholder()
                case .signedIn(let userID, _) where localAccount.owner != userID:
                    // Settled by the task below in a moment.
                    LaunchPlaceholder()
                case .signedIn where preferences.hasOnboarded:
                    AppShell()
                case .signedIn:
                    OnboardingFlow()
                case .needsAccount, .failed:
                    SignInScreen()
                }
            }
        }
        .task(id: session.userID) {
            await settleLocalData()
        }
        // Purchases belong to the Supabase account, so the store learns who
        // is buying whenever that changes: a restored session at launch, or a
        // sign-in. Only once the server has confirmed it: an account shown
        // early from storage may have been deleted, and a purchase made under
        // it would reach nobody.
        .task(id: session.confirmedUserID) {
            await purchases.start(userID: session.confirmedUserID)
            guard session.confirmedUserID != nil else { return }
            await entitlements.refresh()
            await releaseServerTasksIfPending()
        }
    }

    /// What the phone's data means for the account now signed in. See
    /// `LocalAccount`.
    private func settleLocalData() async {
        guard let userID = session.userID, !deletion.requiresCleanup else { return }
        let releases = localAccount.arrived(userID, arrival: session.arrival,
                                            hasLocalData: LocalAccount.hasData(in: context),
                                            preferences: preferences)
        guard localAccount.awaitingDecision == nil else { return }
        if session.arrival == .signedIn {
            // Signed back in: the reminders cleared at sign-out come back.
            await notifications.rebuild(context: context, preferences: preferences, coordinator: coordinator)
        }
        if releases { await releaseServerTasksIfPending() }
    }

    private func releaseServerTasksIfPending() async {
        guard localAccount.releasePending, session.confirmedUserID != nil else { return }
        // Tried again at the next launch if this fails.
        if (try? await session.releaseServerTasks()) != nil {
            localAccount.releaseFinished()
        }
    }
}

/// Shown for the moment it takes to restore a session. Deliberately just the
/// background — a spinner that flashes for 80ms reads as jank.
private struct LaunchPlaceholder: View {
    var body: some View {
        ZStack { BackgroundGradient() }
            .accessibilityLabel("Loading")
    }
}
