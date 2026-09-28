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
    /// When the request was made, for `accountOutlivedRequest`.
    private static let requestedAtKey = "albus.accountDeletion.requestedAt"
    /// How long after a request a renewal of the account's pass proves the
    /// request deleted nothing. A server still carrying out the deletion
    /// could renew the pass moments before the account goes; the server gives
    /// up on a request within seconds, so ten minutes leaves no doubt.
    static let settleAfter: TimeInterval = 10 * 60
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
                defaults.set(Date.now, forKey: Self.requestedAtKey)
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
            defaults.removeObject(forKey: Self.requestedAtKey)
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
    /// renewed this account's pass long enough after the request that the
    /// request cannot still have been under way, so it deleted nothing. Launch
    /// stops waiting on a question that has been answered.
    ///
    /// A renewal sooner than `settleAfter` proves nothing and leaves the mark:
    /// if the deletion is carried out after all, the pass is refused next time
    /// and `adoptLostDeletion` still needs the mark to clean up.
    ///
    /// Never with a request in flight. `SessionService.start(settling:)` calls
    /// this only for a mark set before its restore began, and with the mark set
    /// the app does not open, so no new request can begin, until it returns.
    func accountOutlivedRequest(renewalBegan: Date) {
        guard !isBusy, !requiresCleanup, defaults.bool(forKey: Self.requestKey) else { return }
        guard let requestedAt = defaults.object(forKey: Self.requestedAtKey) as? Date else {
            // A mark from before requests carried their time: its clock starts now.
            defaults.set(renewalBegan, forKey: Self.requestedAtKey)
            return
        }
        guard renewalBegan.timeIntervalSince(requestedAt) >= Self.settleAfter else { return }
        defaults.removeObject(forKey: Self.requestKey)
        defaults.removeObject(forKey: Self.requestedAtKey)
    }
}

extension SessionService {
    /// Launch's restore, with any deletion this phone never heard back about
    /// settled by what the server says.
    ///
    /// The app opens onto the stored account at once, unless such a deletion
    /// is outstanding: its account may be gone, so launch asks the server and
    /// waits for the answer. A refused pass means the deletion happened, and
    /// cleanup starts; a pass renewed well after the request means the
    /// account exists and the request deleted nothing, so later launches open
    /// at once again. No signal settles nothing.
    func start(settling deletion: AccountDeletion) async {
        let unanswered = deletion.hasUnansweredRequest
        await start(opensEarly: !unanswered)
        deletion.adoptLostDeletion(credentialRejected: credentialRejected)
        if unanswered, renewedByServer, let began = renewalBegan {
            deletion.accountOutlivedRequest(renewalBegan: began)
        }
    }

    /// A return to the app's renewal, settling a deletion as launch does: a
    /// pass the server renews well after the request proves it deleted
    /// nothing. Without this, a launch that could not reach the server leaves
    /// the next cold launch waiting on a question already answered. A refused
    /// pass reaches `adoptLostDeletion` through `credentialRejected`.
    func revalidate(settling deletion: AccountDeletion) async {
        guard let began = await revalidate(), deletion.hasUnansweredRequest else { return }
        deletion.accountOutlivedRequest(renewalBegan: began)
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
