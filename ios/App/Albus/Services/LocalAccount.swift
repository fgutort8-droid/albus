import Foundation
import SwiftData

/// Which account the tasks on this phone belong to.
///
/// Tasks live only on the phone: signing in on a new phone brings back the
/// account and its plan, not the tasks (the owner's decision, 2 Oct 2026). So
/// the phone has to know whose tasks it holds. Signing out keeps them, for
/// when the same account signs back in; a different account finds them still
/// here and is asked before they are removed.
@Observable
@MainActor
final class LocalAccount {
    private static let ownerKey = "albus.localData.owner"
    private static let releaseKey = "albus.localData.releasePending"

    /// How the account now signed in got there.
    enum Arrival: Equatable {
        /// Restored from this phone's storage at launch.
        case restored
        /// Signed in just now, on the sign-in screen.
        case signedIn
    }

    enum Decision: Equatable {
        /// The phone's data is this account's.
        case keep
        /// The phone holds nothing of anyone's: it becomes this account's.
        /// `resetsSetUp` clears the set-up answers, which belonged to whoever
        /// was here before; `releasesServerTasks` tells the server that the
        /// account's tasks are not on this phone.
        case adopt(resetsSetUp: Bool, releasesServerTasks: Bool)
        /// Another account's tasks are here. Ask before removing them.
        case ask
    }

    private let defaults: UserDefaults

    /// The account signed in now, while the student decides about another
    /// account's tasks on this phone.
    private(set) var awaitingDecision: UUID?

    /// Bumped whenever the phone stops acting for an account, by signing out
    /// or by removing another account's tasks, so the app replaces the
    /// services that held that account's state.
    private(set) var generation = 0

    /// The account the phone's data belongs to. Stored, not read through,
    /// so the screens update when it changes.
    private(set) var owner: UUID?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        owner = defaults.string(forKey: Self.ownerKey).flatMap(UUID.init(uuidString:))
#if DEBUG
        // UI tests sign in by assumption, as one fixed account, and set the
        // set-up answers with launch arguments. Whatever an earlier run left
        // here, that account owns the phone, so nothing resets those answers.
        if ProcessInfo.processInfo.arguments.contains("-albus.debug.assumeSignedIn") {
            owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        }
#endif
    }

    /// The server still counts tasks this phone does not hold.
    var releasePending: Bool { defaults.bool(forKey: Self.releaseKey) }

    static func decide(for userID: UUID, owner: UUID?, arrival: Arrival, hasLocalData: Bool) -> Decision {
        if owner == userID { return .keep }
        // Data from before the phone kept track belongs to the account it
        // was made under, which is the one restored at launch.
        if owner == nil, arrival == .restored { return .adopt(resetsSetUp: false, releasesServerTasks: false) }
        if !hasLocalData { return .adopt(resetsSetUp: true, releasesServerTasks: true) }
        return .ask
    }

    /// Settles what the phone's data means for the account now signed in.
    ///
    /// - Returns: whether the server should be told the account's tasks are
    ///   not on this phone. `releaseFinished()` records that it was.
    @discardableResult
    func arrived(_ userID: UUID, arrival: Arrival, hasLocalData: Bool, preferences: Preferences) -> Bool {
        switch Self.decide(for: userID, owner: owner, arrival: arrival, hasLocalData: hasLocalData) {
        case .keep:
            awaitingDecision = nil
            return releasePending
        case .adopt(let resetsSetUp, let releases):
            if resetsSetUp { preferences.resetAfterAccountDeletion() }
            adopt(userID, releasing: releases)
            return releasePending
        case .ask:
            awaitingDecision = userID
            return false
        }
    }

    /// The student chose to remove the other account's tasks. `clearLocal`
    /// erases them, exactly as deleting an account does.
    func removeOtherAccountsData(for userID: UUID,
                                 clearLocal: @MainActor () async throws -> Void) async throws {
        guard awaitingDecision == userID else { return }
        try await clearLocal()
        adopt(userID, releasing: true)
        awaitingDecision = nil
        generation += 1
    }

    /// Signed out, or chose not to remove another account's tasks. The tasks
    /// stay, still belonging to their owner.
    func signedOut() {
        awaitingDecision = nil
        generation += 1
    }

    /// The account was deleted and the phone cleared.
    func forget() {
        defaults.removeObject(forKey: Self.ownerKey)
        defaults.removeObject(forKey: Self.releaseKey)
        owner = nil
        awaitingDecision = nil
    }

    func releaseFinished() {
        defaults.removeObject(forKey: Self.releaseKey)
    }

    private func adopt(_ userID: UUID, releasing: Bool) {
        defaults.set(userID.uuidString, forKey: Self.ownerKey)
        owner = userID
        if releasing { defaults.set(true, forKey: Self.releaseKey) }
    }

    /// Whether the phone holds anything a student made. A store that cannot
    /// be counted is taken to hold something, so it is asked about rather
    /// than handed to whoever signed in.
    static func hasData(in context: ModelContext) -> Bool {
        guard let assignments = try? context.fetchCount(FetchDescriptor<Assignment>()),
              let rubrics = try? context.fetchCount(FetchDescriptor<Rubric>()),
              let gradings = try? context.fetchCount(FetchDescriptor<Grading>())
        else { return true }
        return assignments + rubrics + gradings > 0
    }
}

/// Signing out on this phone, from Settings or because Apple says the student
/// stopped using Sign in with Apple for Albus.
@MainActor
enum AccountSignOut {
    /// The tasks stay, for when the same account signs back in. The
    /// reminders go now: they would show the account's task names on the lock
    /// screen with nobody signed in.
    static func perform(session: SessionService, focus: FocusSession,
                        notifications: NotificationCoordinator, context: ModelContext,
                        localAccount: LocalAccount) async throws {
        try await session.signOut()
        focus.cancel(context: context)
        await notifications.clearForAccountDeletion()
        localAccount.signedOut()
    }
}
