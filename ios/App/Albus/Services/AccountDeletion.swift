import Foundation
import SwiftData

@Observable
@MainActor
final class AccountDeletion {
    /// The server confirmed the deletion; this phone has not finished clearing.
    private static let receiptKey = "albus.accountDeletion.pendingCleanup"
    /// The student asked, and the server's answer may never have arrived.
    ///
    /// Written *before* the request, because the failure this guards against
    /// is a request that succeeds and whose answer is lost. Nothing is erased
    /// on the strength of this mark alone: it only says an unanswered question
    /// is outstanding, and `adoptLostDeletion` is where it is answered.
    private static let requestKey = "albus.accountDeletion.requested"
    private let defaults: UserDefaults
    private(set) var requiresCleanup: Bool
    private(set) var isBusy = false
    private(set) var generation = 0
    var errorMessage: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        requiresCleanup = defaults.bool(forKey: Self.receiptKey)
    }

    func perform(deleteRemote: @MainActor () async throws -> Void,
                 clearLocal: @MainActor () async throws -> Void,
                 signOut: @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        if !requiresCleanup {
            // Before the request, not after: a lost answer must still leave
            // this phone knowing a deletion is outstanding.
            defaults.set(true, forKey: Self.requestKey)
            do {
                try await deleteRemote()
            } catch is AccountUnreachable {
                // The account cannot be reached from this device any more, and
                // for an anonymous account there is no other way in. Carrying
                // on is the only outcome that keeps the promise this screen
                // made; refusing would leave the work here for good.
            } catch {
                // A dropped response cannot establish whether the server committed.
                // Keep local work and credentials so the same idempotent RPC can retry.
                if (error as? URLError)?.code == .notConnectedToInternet {
                    errorMessage = "Couldn't delete your account. You're offline. Nothing on this device was changed. Reconnect and try again."
                } else {
                    errorMessage = "Couldn't confirm account deletion. Nothing on this device was changed. Please try again."
                }
                return false
            }
            defaults.set(true, forKey: Self.receiptKey)
            requiresCleanup = true
            generation += 1
        }

        do {
            try await clearLocal()
            try await signOut()
            defaults.removeObject(forKey: Self.receiptKey)
            defaults.removeObject(forKey: Self.requestKey)
            requiresCleanup = false
            return true
        } catch {
            // The account is already gone. A durable receipt prevents a restart
            // exposing its old cache or asking the student to delete it again.
            errorMessage = "Your account was deleted, but Albus couldn't finish clearing this phone. Tap Try again to finish."
            return false
        }
    }

    /// Settles a deletion whose answer never arrived, at launch.
    ///
    /// Two facts together are conclusive, and neither is on its own: the
    /// student asked for deletion, and the stored credential has since been
    /// refused. An anonymous account has no password and no second way in, so
    /// a refused credential means this phone can never reach that account
    /// again — which, for an account that was asked to be deleted, is because
    /// it is gone.
    ///
    /// Without this, that student's next launch shows onboarding, because the
    /// session cannot be restored, while every assignment, rubric and mark
    /// they asked Albus to delete is still in the store — and the new account
    /// they make adopts the lot.
    ///
    /// `credentialRejected` is false when the phone merely had no signal, so
    /// nothing is erased on the evidence of a tunnel.
    func adoptLostDeletion(credentialRejected: Bool) {
        guard !requiresCleanup,
              credentialRejected,
              defaults.bool(forKey: Self.requestKey)
        else { return }
        defaults.set(true, forKey: Self.receiptKey)
        requiresCleanup = true
        generation += 1
    }
}

@MainActor
enum AccountLocalData {
    static func erase(context: ModelContext, preferences: Preferences, defaults: UserDefaults = .standard) throws {
        context.rollback()
        for model in AlbusSchema.models {
            try context.delete(model: model)
        }
        try context.save()
        preferences.resetAfterAccountDeletion()
        PendingDeletions.clear(defaults: defaults)
    }
}
