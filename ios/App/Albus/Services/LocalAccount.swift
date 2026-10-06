import Foundation
import SwiftData

/// Which account the tasks on this phone belong to.
///
/// Tasks live only on the phone: signing in on a new phone brings back the
/// account and its plan, not the tasks (the owner's decision, 2 Oct 2026). So
/// the phone has to know whose tasks it holds. Signing out keeps them, for
/// when the same account signs back in; a different account finds them still
/// here and is asked before they are removed.
///
/// Nothing here touches the server's count of open tasks. Tasks the phone
/// does not hold may be in use on another phone, and only the student knows,
/// so they are freed from Home, when the student asks (`PlanCoordinator.releaseOthers`).
@Observable
@MainActor
final class LocalAccount {
    private static let ownerKey = "albus.localData.owner"

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
        /// was here before.
        case adopt(resetsSetUp: Bool)
        /// Another account's tasks are here. Ask before removing them.
        case ask
    }

    private let defaults: UserDefaults

    /// The account signed in now, while the student decides about another
    /// account's tasks on this phone.
    private(set) var awaitingDecision: UUID?

    /// Bumped whenever the phone stops acting for an account, by signing out,
    /// by removing another account's tasks, or by another account taking an
    /// empty phone over, so the app replaces the services that held that
    /// account's state, such as its plan.
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

    static func decide(for userID: UUID, owner: UUID?, arrival: Arrival, hasLocalData: Bool) -> Decision {
        if owner == userID { return .keep }
        // Data from before the phone kept track belongs to the account it
        // was made under, which is the one restored at launch.
        if owner == nil, arrival == .restored { return .adopt(resetsSetUp: false) }
        if !hasLocalData { return .adopt(resetsSetUp: true) }
        return .ask
    }

    /// Settles what the phone's data means for the account now signed in.
    func arrived(_ userID: UUID, arrival: Arrival, hasLocalData: Bool, preferences: Preferences) {
        switch Self.decide(for: userID, owner: owner, arrival: arrival, hasLocalData: hasLocalData) {
        case .keep:
            awaitingDecision = nil
        case .adopt(let resetsSetUp):
            if resetsSetUp { preferences.resetAfterAccountDeletion() }
            let replacesAnother = owner != nil
            adopt(userID)
            // The services may still hold the other account's plan. Replaced
            // here as at sign-out, so a refresh that fails cannot leave this
            // student looking at someone else's.
            if replacesAnother { generation += 1 }
        case .ask:
            awaitingDecision = userID
        }
    }

    /// The student chose to remove the other account's tasks. `clearLocal`
    /// erases them, exactly as deleting an account does.
    func removeOtherAccountsData(for userID: UUID,
                                 clearLocal: @MainActor () async throws -> Void) async throws {
        guard awaitingDecision == userID else { return }
        try await clearLocal()
        adopt(userID)
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
        owner = nil
        awaitingDecision = nil
    }

    private func adopt(_ userID: UUID) {
        defaults.set(userID.uuidString, forKey: Self.ownerKey)
        owner = userID
    }

    /// Whether the phone holds anything a student made, of any kind: a
    /// course saved before its first task is still theirs. Every model in the
    /// schema is counted, so a new one cannot be missed. A store that cannot
    /// be counted is taken to hold something, so it is asked about rather
    /// than handed to whoever signed in.
    static func hasData(in context: ModelContext) -> Bool {
        for model in AlbusSchema.models {
            guard let rows = rowCount(of: model, in: context) else { return true }
            if rows > 0 { return true }
        }
        return false
    }

    private static func rowCount<M: PersistentModel>(of model: M.Type, in context: ModelContext) -> Int? {
        try? context.fetchCount(FetchDescriptor<M>())
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
