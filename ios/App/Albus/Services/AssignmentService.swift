import Foundation
import Supabase

/// Removing an assignment from the server.
///
/// Deletion is not cosmetic here. The free-plan cap counts *server* rows, so an
/// assignment deleted on the device but left on the server keeps consuming one
/// of the student's three active plans — they would delete three things and
/// still be told they had reached their limit, with nothing on screen to
/// explain it.
///
/// Everything below the assignment goes with it without being named: subtasks,
/// plan sessions and gradings are all `on delete cascade`, and RLS scopes the
/// delete to the caller's own rows, so a forged id removes nothing.
struct AssignmentService {

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// True when the row is gone from the server — or was never there.
    func delete(remoteID: UUID) async -> Bool {
        guard let client else { return false }
        do {
            try await client.from("assignments")
                .delete()
                .eq("id", value: remoteID.uuidString.lowercased())
                .execute()
            return true
        } catch {
            print("[Albus] assignment delete failed: \(error)")
            return false
        }
    }
}

/// Server deletions that have not landed yet.
///
/// The device deletes immediately, because waiting on the network to remove
/// something the student just asked to remove feels broken. When the server
/// call fails — offline, mid-flight — the id is kept here and retried, so the
/// row cannot be stranded server-side holding a plan slot open forever.
///
/// `UserDefaults` rather than the store: these are a handful of ids belonging to
/// rows that no longer exist locally, and putting them in SwiftData would mean a
/// model whose only purpose is to describe absence.
@MainActor
enum PendingDeletions {
    private static let key = "albus.pendingAssignmentDeletions"
    private static var generation = 0

    static func record(_ id: UUID) {
        var ids = all()
        guard !ids.contains(id) else { return }
        ids.append(id)
        save(ids)
    }

    static func clear(defaults: UserDefaults = .standard) {
        generation += 1
        defaults.removeObject(forKey: key)
    }

    static func all() -> [UUID] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func save(_ ids: [UUID]) {
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }

    /// Retries everything outstanding, dropping whatever succeeds. Safe to call
    /// on every launch: with nothing pending it does no work and no network.
    static func flush(using service: AssignmentService = AssignmentService()) async {
        let startedGeneration = generation
        let pending = all()
        guard !pending.isEmpty else { return }

        var stillPending: [UUID] = []
        for id in pending where await !service.delete(remoteID: id) {
            stillPending.append(id)
        }
        guard generation == startedGeneration else { return }
        save(stillPending)
    }
}
