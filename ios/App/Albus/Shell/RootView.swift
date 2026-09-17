import SwiftUI
import AlbusCore

/// Chooses between onboarding and the app.
///
/// The condition is deliberately "has an account AND has finished onboarding",
/// not one or the other. A student who quits midway through onboarding has an
/// account but no plan, and dropping them into an empty Today would waste the
/// one moment they are willing to spend on setup.
struct RootView: View {
    @Environment(SessionService.self) private var session
    @Environment(AccountDeletion.self) private var deletion
    @Environment(Preferences.self) private var preferences
    @Environment(PurchaseService.self) private var purchases

    var body: some View {
        Group {
            if deletion.requiresCleanup {
                AccountDeletionScreen(recovering: true)
            } else {
                switch session.state {
                case .starting:
                    LaunchPlaceholder()
                case .signedIn where preferences.hasOnboarded:
                    AppShell()
                case .signedIn, .needsAccount, .failed:
                    // `.failed` lands here too: onboarding is where the retry
                    // lives, and a student with no connection on first launch
                    // should see the questions rather than a dead end.
                    OnboardingFlow()
                }
            }
        }
        // Purchases belong to the Supabase account, so the store learns who
        // is buying whenever that changes: a restored session at launch, or
        // the account onboarding creates.
        .task(id: session.userID) {
            await purchases.start(userID: session.userID)
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
