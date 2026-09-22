import Foundation
import SwiftData
import UserNotifications
import AlbusCore

/// Keeps what iOS holds in step with what the planner decided.
///
/// The stateful half of notifications: `NotificationScheduler` stays a
/// stateless `Sendable` struct so `FocusSession` can keep injecting it, and
/// everything that has to remember something lives here — mirroring how
/// `PlanCoordinator` holds `Scheduler`.
@Observable
@MainActor
final class NotificationCoordinator {

    /// Set when a rebuild found the student had switched notifications off in
    /// iOS Settings, so a screen can offer a way back rather than looking broken.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined
    /// What was scheduled last, for the settings screen to show.
    private(set) var scheduledCount = 0

    private let client: NotificationCenterClient
    private let state: NotificationState
    private let planner = NotificationPlanner()

    /// Coalesces the burst of rebuilds a single gesture produces.
    ///
    /// Reordering steps calls `reschedule` several times in a row; without this
    /// each one would round-trip to the notification daemon.
    private var suspendedForDeletion = false
    private var pending: Task<Void, Never>?
    private static let debounce: Duration = .milliseconds(400)

    init(client: NotificationCenterClient = NotificationScheduler(),
         state: NotificationState = NotificationState()) {
        self.client = client
        self.state = state
    }

    // MARK: - Public surface

    /// Registers the action buttons. Once per launch is enough.
    func registerCategories() async {
        await client.setCategories()
    }

    /// The app came to the front.
    func appDidBecomeActive(now: Date = .now) {
        state.recordAppOpen(now: now)
    }

    /// The student tapped a notification, which is the strongest possible
    /// signal that these are worth sending.
    func recordEngagement(now: Date = .now) {
        state.recordEngagement(now: now)
    }

    /// Rebuilds after a short delay, collapsing a burst into one pass.
    func scheduleRebuild(context: ModelContext,
                         preferences: Preferences,
                         coordinator: PlanCoordinator) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await self?.rebuild(context: context, preferences: preferences,
                                coordinator: coordinator)
        }
    }

    /// Recomputes the desired set and makes iOS match it.
    ///
    /// Idempotent by construction: it computes what *should* be pending, then
    /// removes what should not be and adds what is missing. Nothing here knows
    /// about deletion, completion or editing specifically — an assignment that
    /// is gone simply produces no identifiers, so its notifications disappear
    /// as a consequence of the diff rather than as a special case.
    func rebuild(context: ModelContext,
                 preferences: Preferences,
                 coordinator: PlanCoordinator,
                 now: Date = .now) async {
        guard !suspendedForDeletion else { return }
        authorization = await client.authorizationStatus()
        guard !suspendedForDeletion else { return }

        // A denied or unanswered app must never add anything: `add` succeeds
        // regardless and the request sits pending but unpresentable, which
        // makes a broken permission look identical to a working one.
        guard authorization == .authorized || authorization == .provisional else {
            scheduledCount = 0
            return
        }

        guard preferences.notificationsEnabled else {
            await clearAll()
            return
        }

        // A failed re-flow leaves the mood and the unplaced set describing a
        // plan that was never built. Saying anything about it would report a
        // state the student cannot see or fix.
        guard coordinator.lastRunSucceeded else { return }

        let planned = planner.plan(makeContext(context, preferences, coordinator, now: now))

        let fingerprint = planned
            .map { "\($0.id):\($0.fingerprint)" }
            .sorted()
            .joined(separator: "|")
        let digest = StableHash.string(fingerprint)
        guard digest != state.digest else { return }

        await apply(planned, now: now)
        guard !suspendedForDeletion else { return }

        state.digest = digest
        state.unfitSignature = StableHash.signature(coordinator.unplacedStepIDs)
        state.recordScheduled(planned.map(\.fireDate), now: now)
        scheduledCount = planned.count

        // Notifications are the one feature whose output the developer cannot
        // see: it arrives on a lock screen, hours later, on someone else's
        // phone. One line per rebuild is what makes "why did it say that"
        // answerable at all, on device as much as here.
        print("[Albus] scheduled \(planned.count): "
              + planned.sorted { $0.fireDate < $1.fireDate }
                  .map { "\($0.kind.rawValue)@\(Self.log.string(from: $0.fireDate))" }
                  .joined(separator: ", "))
    }

    private static let log: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE HH:mm"
        return formatter
    }()

    /// Removes everything the plan owns, leaving the focus session alone.
    func clearAll() async {
        let pending = await client.pendingIdentifiers()
        // Same reason as in `apply`: the focus session's alert is not ours to
        // cancel, and "switch notifications off" must not silently kill a
        // timer the student is running right now.
        await client.remove(identifiers: pending.keys.filter {
            $0.hasPrefix(NotificationScheduler.planPrefix)
        })
        state.digest = ""
        scheduledCount = 0
    }

    func clearForAccountDeletion() async {
        suspendedForDeletion = true
        pending?.cancel()
        pending = nil
        await clearAll()
        state.reset()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: - The diff

    private func apply(_ planned: [PlannedNotification], now: Date) async {
        let existing = await client.pendingIdentifiers()
        guard !suspendedForDeletion else { return }
        let desired = Dictionary(planned.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // The prefix check is deliberately repeated here even though the client
        // already filters. It is the invariant that stops a rebuild deleting a
        // running focus timer's only alert, and an invariant that lives in one
        // place and is relied on in another is one refactor from being lost.
        let stale = existing.keys.filter {
            $0.hasPrefix(NotificationScheduler.planPrefix) && desired[$0] == nil
        }
        await client.remove(identifiers: Array(stale))

        for notification in planned {
            guard !suspendedForDeletion else { return }
            // `add` with an existing identifier replaces in place, so unchanged
            // requests are skipped rather than torn down and rebuilt — which
            // would open a window where nothing is pending.
            guard existing[notification.id] != notification.fingerprint else { continue }
            // Resolved here and passed in, because rendering the cactus is the
            // one part of building a request that needs the main actor. Handing
            // `request` a plain file URL is what keeps it `nonisolated`.
            let artwork = CactusAttachment.shared.masterURL(for: notification.mood)
            await client.add(notification, artwork: artwork)
            if suspendedForDeletion {
                await client.remove(identifiers: [notification.id])
                return
            }
        }
    }

    // MARK: - Gathering

    private func makeContext(_ context: ModelContext,
                             _ preferences: Preferences,
                             _ coordinator: PlanCoordinator,
                             now: Date) -> NotificationContext {
        let assignments = (try? context.fetch(FetchDescriptor<Assignment>())) ?? []
        let sessions = (try? context.fetch(FetchDescriptor<PlanSessionRecord>())) ?? []
        let weekAgo = now.addingTimeInterval(-7 * 86_400)

        return NotificationContext(
            assignments: PlanBridge.notificationAssignments(
                from: assignments, unplacedStepIDs: coordinator.unplacedStepIDs
            ),
            blocks: PlanBridge.notificationBlocks(from: sessions),
            workload: coordinator.workload,
            availability: preferences.availability,
            settings: preferences.notificationSettings,
            weeklyFocusedMinutes: PlanBridge.focusedMinutes(
                from: sessions, since: weekAgo, until: now
            ),
            previousWeeklyFocusedMinutes: PlanBridge.focusedMinutes(
                from: sessions, since: weekAgo.addingTimeInterval(-7 * 86_400), until: weekAgo
            ),
            lastOpened: state.lastOpened,
            unplaceableCount: coordinator.unplacedStepIDs.count,
            unplaceableSignature: StableHash.signature(coordinator.unplacedStepIDs),
            previousUnplaceableSignature: state.unfitSignature,
            pausedUntil: state.pausedUntil,
            now: now
        )
    }
}
