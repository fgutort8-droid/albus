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
    /// is a request that succeeds and whose answer is lost; but only after the
    /// server has answered `confirmAccount`, so an attempt that never left the
    /// phone leaves no mark. Nothing is erased on the strength of this mark
    /// alone: it only says an unanswered question is outstanding, and
    /// `adoptLostDeletion` and `accountOutlivedRequest` are where it is answered.
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

    /// The student asked for a deletion whose answer never arrived. Until the
    /// server settles it, the app must not open onto the account as if nothing
    /// had happened: see `SessionService.start(opensEarly:)`.
    var hasUnansweredRequest: Bool {
        !requiresCleanup && defaults.bool(forKey: Self.requestKey)
    }

    /// - Parameters:
    ///   - confirmAccount: asks the server whether the account still exists,
    ///     deleting nothing. Throws `AccountUnreachable` if it is already gone.
    ///   - deleteRemote: the request that deletes it.
    func perform(confirmAccount: @MainActor () async throws -> Void,
                 deleteRemote: @MainActor () async throws -> Void,
                 clearLocal: @MainActor () async throws -> Void,
                 signOut: @MainActor () async throws -> Void) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }

        if !requiresCleanup {
            var asked = false
            do {
                // A question first, which deletes nothing. A phone with no
                // signal stops here, before any request that could delete the
                // account has left it: nothing is outstanding, so launch keeps
                // opening straight onto the plans.
                try await confirmAccount()
                // Before the request, not after: a lost answer must still leave
                // this phone knowing a deletion is outstanding.
                defaults.set(true, forKey: Self.requestKey)
                asked = true
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
                } else if !asked {
                    errorMessage = "Couldn't reach Albus to delete your account. Nothing was changed. Please try again."
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

    /// Settles a deletion whose answer never arrived, the other way: the server
    /// has since renewed this account's pass, so the account exists and the
    /// request deleted nothing. Launch stops waiting on a question that has
    /// been answered.
    ///
    /// Only for a renewal that began after the request, with no request in
    /// flight. `SessionService.start(settling:)` guarantees both: it calls this
    /// only when the mark was already set before the restore began, and with
    /// it set the app does not open, so no new request can begin, until the
    /// restore returns.
    func accountOutlivedRequest() {
        guard !isBusy, !requiresCleanup else { return }
        defaults.removeObject(forKey: Self.requestKey)
    }
}

extension SessionService {
    /// Launch's restore, with any deletion this phone never heard back about
    /// settled by what the server says.
    ///
    /// The app opens onto the stored account at once, unless such a deletion
    /// is outstanding: its account may be gone, so launch waits for the
    /// server. A refused pass means the deletion happened, and cleanup starts;
    /// a renewed one means the account exists and the request deleted nothing,
    /// so later launches open at once again. No signal settles nothing.
    func start(settling deletion: AccountDeletion) async {
        let unanswered = deletion.hasUnansweredRequest
        await start(opensEarly: !unanswered)
        deletion.adoptLostDeletion(credentialRejected: credentialRejected)
        if unanswered, renewedByServer { deletion.accountOutlivedRequest() }
    }
}

@MainActor
enum AccountLocalData {
    /// Set only when the app falls back from its own disk store to memory.
    static var recoveryStoreURL: URL?
    static func erase(context: ModelContext, preferences: Preferences, defaults: UserDefaults = .standard) throws {
        context.rollback()
        for model in AlbusSchema.models {
            try context.delete(model: model)
        }
        try context.save()
        let diskStores = context.container.configurations.filter { !$0.isStoredInMemoryOnly }.map(\.url)
        for url in diskStores { try removeQuarantinedStores(at: url) }
        if diskStores.isEmpty, let url = recoveryStoreURL {
            try removeQuarantinedStores(at: url, includingOriginal: true)
        }
        preferences.resetAfterAccountDeletion()
        PendingDeletions.clear(defaults: defaults)
        PendingRubricDeletions.clear(defaults: defaults)
    }

    static func removeQuarantinedStores(at store: URL, includingOriginal: Bool = false) throws {
        let fm = FileManager.default
        let directory = store.deletingLastPathComponent()
        guard fm.fileExists(atPath: directory.path) else { return }
        let prefix = NSRegularExpression.escapedPattern(for: store.lastPathComponent)
        let pattern = "^" + prefix + #"\.corrupt-\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}Z(?:-wal|-shm)?$"#
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) {
            let original = ["", "-wal", "-shm"].contains { file.lastPathComponent == store.lastPathComponent + $0 }
            guard (includingOriginal && original)
                || file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil else { continue }
            let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Never recursively remove a directory or follow a symlink.
            guard values.isDirectory != true || values.isSymbolicLink == true else {
                throw CocoaError(.fileWriteNoPermission)
            }
            try fm.removeItem(at: file)
        }
    }

}
