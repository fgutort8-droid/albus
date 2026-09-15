import Foundation
import UserNotifications
import AlbusCore

/// The parts of `UNUserNotificationCenter` Albus uses.
///
/// A protocol so tests can watch what was scheduled without a notification
/// daemon. In the simulator `UNUserNotificationCenter.current()` talks to a real
/// system service that a unit test has no business waking, and which can hang.
/// **Only `Sendable` types cross this boundary, deliberately.**
///
/// It used to take a built `UNNotificationRequest`, marked `sending` to hand
/// over sole ownership. That is legal Swift and it type-checked here, but it
/// made every implementation responsible for receiving a non-`Sendable` value:
/// an `actor` conforming to it is rejected outright by Swift 6.1, which is what
/// kept CI red. Passing the plan and letting the implementation phrase the
/// request removes the problem rather than annotating around it — and it puts
/// the phrasing next to the daemon that consumes it.
protocol NotificationCenterClient: Sendable {
    /// `artwork` is the rendered cactus, resolved by the caller because
    /// rendering needs the main actor and a `URL` is `Sendable`.
    func add(_ notification: PlannedNotification, artwork: URL?) async
    func pendingIdentifiers() async -> [String: String]
    func remove(identifiers: [String]) async
    func authorizationStatus() async -> UNAuthorizationStatus
    /// No parameter: the categories are a compile-time constant, so passing
    /// them only moved a non-`Sendable` `Set` across for no decision.
    func setCategories() async
}

/// Tells the student when a focus session has finished, and delivers everything
/// `NotificationPlanner` decides to say.
///
/// **Deliberately still a stateless `Sendable` struct.** `UNUserNotificationCenter`
/// is not Sendable, so the moment this holds one it stops crossing isolation
/// boundaries — and `FocusSession` injects it from inside a `@MainActor` class
/// into async work. Everything with state lives in `NotificationCoordinator`
/// instead, which holds one of these.
///
/// **Two namespaces, and the split is load-bearing.** `albus.session.*` belongs
/// to `FocusSession`; `albus.plan.*` belongs to the rebuild. A rebuild that
/// called `removeAllPendingNotificationRequests` would delete a running focus
/// timer's only alert, because `reschedule` can fire while a session is live.
struct NotificationScheduler: Sendable, NotificationCenterClient {

    /// Everything the plan rebuild owns, and nothing else.
    static let planPrefix = "albus.plan."

    /// One identifier, reused: there is only ever one session running, so
    /// scheduling a new completion replaces any stale one rather than stacking.
    private static let completionID = "albus.session.complete"

    /// Resolved per call rather than stored.
    ///
    /// `UNUserNotificationCenter` is not Sendable, so holding one would stop
    /// this type crossing an isolation boundary — and it is created inside an
    /// @Observable @MainActor class and used from async work. `current()` is a
    /// cheap singleton lookup, so there is nothing to gain by keeping it.
    private var center: UNUserNotificationCenter { .current() }

    /// Asks for permission, returning whether it was granted.
    ///
    /// Never throws upward: a refused prompt must not stop a session starting.
    /// The session still runs and still shows its countdown; the student just
    /// has to be looking.
    ///
    /// **`.badge` is requested even though nothing sets one yet, and that is a
    /// one-way door.** iOS shows the permission sheet once; a later call asking
    /// for options the student was never asked about does not re-prompt and
    /// does not grant them. Adding it after the first release would mean every
    /// existing student is permanently unable to receive a badge. It costs
    /// nothing now — the sheet looks identical to the student either way.
    @discardableResult
    func requestPermission() async -> Bool {
#if DEBUG
        // UI tests cannot answer this prompt. Under XCUITest it never presents,
        // so an awaited request never returns and onboarding's "Show me" waits
        // forever on a freshly erased device. Compiled out of Release, and it
        // grants nothing: the permission is reported as not given.
        if ProcessInfo.processInfo.arguments.contains("-albus.debug.skipNotificationPrompt") {
            return false
        }
#endif
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    /// What the student has actually granted.
    ///
    /// Everything that schedules has to be able to ask this: `add` succeeds
    /// while unauthorised and the request simply never presents, so without
    /// checking, a denied app looks identical to a working one from the inside.
    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    /// Fires once, when the session's remaining time runs out.
    func scheduleCompletion(in seconds: Int, title: String) {
        cancelCompletion()
        guard seconds > 0 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Session finished"
        // The step's own name, so a glance at the lock screen says what is done.
        content.body = title
        content.sound = .default

        let trigger = UNTimeIntervalNotificationTrigger(
            timeInterval: TimeInterval(seconds), repeats: false
        )
        center.add(UNNotificationRequest(identifier: Self.completionID,
                                         content: content, trigger: trigger))
    }

    /// Pausing, ending early or finishing in-app all make the pending alert
    /// wrong. Removing it is what stops a notification arriving for a session
    /// the student already closed.
    func cancelCompletion() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.completionID])
    }

    // MARK: - NotificationCenterClient

    func add(_ notification: PlannedNotification, artwork: URL?) async {
        try? await center.add(Self.request(for: notification, artwork: artwork))
    }

    /// Pending plan notifications, as id → content fingerprint.
    ///
    /// The fingerprint rides in `userInfo` rather than in a side table, so the
    /// pending set is self-describing and the diff cannot drift out of sync
    /// with what iOS actually holds.
    func pendingIdentifiers() async -> [String: String] {
        let pending = await center.pendingNotificationRequests()
        return pending.reduce(into: [:]) { result, request in
            guard request.identifier.hasPrefix(Self.planPrefix) else { return }
            result[request.identifier] = request.content.userInfo["fp"] as? String ?? ""
        }
    }

    func remove(identifiers: [String]) async {
        guard !identifiers.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func setCategories() async {
        center.setNotificationCategories(NotificationActions.categories)
    }

    /// Phrases a planned notification as something `UNUserNotificationCenter`
    /// accepts.
    ///
    /// `static` and free of any isolation, so what it returns belongs to no
    /// actor's region and a test can check the mapping without a daemon. It
    /// lives here rather than in `NotificationCoordinator` because the
    /// coordinator decides *what* to say and this decides how to say it to iOS.
    static func request(for notification: PlannedNotification,
                        artwork: URL?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        // The fingerprint rides in `userInfo` because `pendingIdentifiers()`
        // reads it back out to diff against — the pending set has to be
        // self-describing.
        content.userInfo = ["fp": notification.fingerprint,
                            "kind": notification.kind.rawValue]
        if let thread = notification.threadID { content.threadIdentifier = thread }
        content.categoryIdentifier = NotificationActions.category(for: notification.kind)

        // Tier 1 is a consequence rather than a nudge, so it sorts above the
        // rest inside a Scheduled Summary.
        content.relevanceScore = notification.kind.tier == 1 ? 1.0 : 0.5
        content.interruptionLevel = NotificationCapabilities.level(for: notification.kind)

        if let attachment = CactusAttachment.attachment(copyingMaster: artwork,
                                                        mood: notification.mood) {
            content.attachments = [attachment]
        }

        // Calendar components rather than a time interval, deliberately.
        // "Seconds until 07:30" computed today fires an hour off once the
        // clocks change; wall-clock components stay correct across DST and
        // across a student flying somewhere.
        var parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: notification.fireDate
        )
        parts.timeZone = .current
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)

        return UNNotificationRequest(identifier: notification.id,
                                     content: content, trigger: trigger)
    }
}
