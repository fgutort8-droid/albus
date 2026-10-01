import SwiftUI
import UserNotifications
import AlbusCore

/// Handles a tap on a notification, and decides what to show while the app is
/// already open.
///
/// **There was no `UNUserNotificationCenterDelegate` in this app at all.**
/// Without one, tapping a notification only launches the app — it cannot open
/// the assignment the notification was about, action buttons cannot be handled,
/// and there is no way to learn that a student ever responded.
@Observable
@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {

    /// The assignment a tap asked for. A screen observes this and navigates.
    var requestedAssignment: UUID?
    /// The grading a "feedback is ready" tap asked for, as the local
    /// `Grading.id`. The app shell observes this and opens it.
    var requestedGrading: UUID?
    /// True when the tap came from "Start it", so the destination can go
    /// straight into Focus Mode rather than to the plan.
    var wantsFocus = false

    /// Set once the app has wired itself up, so a rebuild can be triggered
    /// without this type reaching into the store itself.
    var onEngagement: (@MainActor () -> Void)?

    /// Shown while the app is in the foreground.
    ///
    /// Only for things the student cannot see by looking. A nudge for a block
    /// starting in ten minutes is redundant when they are already in the app;
    /// "your plan no longer fits" is not, because nothing on screen says so
    /// unless they happen to be on that assignment.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let raw = notification.request.content.userInfo["kind"] as? String
        guard let kind = raw.flatMap(NotificationKind.init(rawValue:)), kind.tier == 1 else {
            return []
        }
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let content = response.notification.request.content
        let thread = content.threadIdentifier
        let action = response.actionIdentifier

        await MainActor.run {
            // Any interaction at all is evidence these are worth sending, and
            // is what clears an ignored streak.
            onEngagement?()

            // "Not today" is a deliberate dismissal: acknowledged, no navigation.
            guard action != NotificationActions.ID.notToday else { return }

            if let grading = Self.gradingID(fromThread: thread) {
                requestedGrading = grading
                return
            }
            wantsFocus = action == NotificationActions.ID.start
            requestedAssignment = Self.assignmentID(fromThread: thread)
        }
    }

    /// Thread identifiers for finished markings are `albus.grading.<uuid>`,
    /// parsed as strictly as the assignment ones.
    static func gradingID(fromThread thread: String) -> UUID? {
        let prefix = "albus.grading."
        guard thread.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(thread.dropFirst(prefix.count)))
    }

    /// Thread identifiers are `albus.assignment.<uuid>`.
    ///
    /// Parsed rather than trusted: this string comes back through the system,
    /// and a malformed one should route nowhere rather than crash.
    static func assignmentID(fromThread thread: String) -> UUID? {
        let prefix = "albus.assignment."
        guard thread.hasPrefix(prefix) else { return nil }
        return UUID(uuidString: String(thread.dropFirst(prefix.count)))
    }

    func clearRoute() {
        requestedAssignment = nil
        wantsFocus = false
    }

    func clearGradingRoute() {
        requestedGrading = nil
    }
}
