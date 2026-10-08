import Foundation
import UserNotifications
import AlbusCore

/// The buttons under a notification.
///
/// Worth having because they need no entitlement and no Team ID, and they are
/// the most Duolingo-shaped thing available to an unsigned build: the student
/// can act without unlocking into the app.
enum NotificationActions {

    enum ID {
        static let start = "albus.action.start"
        static let notToday = "albus.action.notToday"
        static let replan = "albus.action.replan"
    }

    enum Category {
        static let nudge = "albus.category.nudge"
        static let deadline = "albus.category.deadline"
        static let unfit = "albus.category.unfit"
        static let plain = "albus.category.plain"
    }

    /// Which buttons belong under which kind.
    static func category(for kind: NotificationKind) -> String {
        switch kind {
        case .windowNudge, .morningBrief: Category.nudge
        case .deadline72, .deadline24, .deadline03, .handInToday, .overdue: Category.deadline
        case .planStoppedFitting: Category.unfit
        case .dormantSoft, .dormantFinal, .backOff, .momentum: Category.plain
        }
    }

    /// Built per call rather than stored.
    ///
    /// `UNNotificationCategory` is not `Sendable`, so a `static let` would be
    /// shared mutable state under Swift 6. This is read once per launch, so
    /// there is nothing to gain by caching it — the same reasoning
    /// `NotificationScheduler` uses for resolving its centre per call.
    static var categories: Set<UNNotificationCategory> {[
        UNNotificationCategory(
            identifier: Category.nudge,
            actions: [
                UNNotificationAction(identifier: ID.start, title: "Start it",
                                     options: [.foreground]),
                // No `.destructive`: dismissing a nudge is an ordinary choice,
                // and styling it as damage would be a small lie about it.
                UNNotificationAction(identifier: ID.notToday, title: "Not today", options: [])
            ],
            intentIdentifiers: [], options: []
        ),
        UNNotificationCategory(
            identifier: Category.deadline,
            actions: [
                UNNotificationAction(identifier: ID.start, title: "Open plan",
                                     options: [.foreground])
            ],
            intentIdentifiers: [], options: []
        ),
        UNNotificationCategory(
            identifier: Category.unfit,
            actions: [
                UNNotificationAction(identifier: ID.replan, title: "Look at it",
                                     options: [.foreground])
            ],
            intentIdentifiers: [], options: []
        ),
        UNNotificationCategory(identifier: Category.plain, actions: [],
                               intentIdentifiers: [], options: [])
    ]}
}

/// What this build is actually allowed to do.
///
/// Present, inert, and one configuration value away from working — rather
/// than absent and rediscovered later.
enum NotificationCapabilities {

    /// True only once `DEVELOPMENT_TEAM` is set and the app is signed.
    /// See `ios/README.md` § "Signing is deliberately unset".
    static var isSignedBuild: Bool {
        (Bundle.main.infoDictionary?["ALBUS_SIGNED_BUILD"] as? String) == "YES"
    }

    /// Time Sensitive needs `com.apple.developer.usernotifications.time-sensitive`,
    /// which needs a provisioning profile, which needs a Team ID.
    ///
    /// **Be honest about what this branch is.** Setting `.timeSensitive` without
    /// the entitlement is ignored by iOS and degrades silently to `.active` — it
    /// does not crash and does not fail delivery. The branch is here to make the
    /// capability legible and to be the one line that changes when the Team ID
    /// arrives, not because it is load-bearing today.
    static func level(for kind: NotificationKind) -> UNNotificationInterruptionLevel {
        guard kind.tier == 1, isSignedBuild else {
            return kind.tier == 1 ? .active : .passive
        }
        return .timeSensitive
    }
}
