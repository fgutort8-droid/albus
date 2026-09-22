import Foundation
import SwiftData

@Observable
@MainActor
final class AccountDeletion {
    private static let receiptKey = "albus.accountDeletion.pendingCleanup"
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
            do {
                try await deleteRemote()
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
            requiresCleanup = false
            return true
        } catch {
            // The account is already gone. A durable receipt prevents a restart
            // exposing its old cache or asking the student to delete it again.
            errorMessage = "Your account was deleted, but Albus couldn't finish clearing this phone. Tap Try again to finish."
            return false
        }
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
