import Foundation
import Supabase

/// Pushes a saved rubric to the server.
///
/// The rubric has to exist server-side because that is where it is used: the
/// breakdown grounds steps in it, and grading marks against it. Both load it by
/// id through the *caller's* own client, so RLS decides what a given id resolves
/// to — which is why neither endpoint ever accepts rubric text from the request
/// body. A forged id resolves to nothing instead of to someone else's rubric.
///
/// Writing is a single RPC rather than two PostgREST calls. Replacing criteria
/// is a delete plus an insert, and split across two requests a dropped
/// connection leaves a rubric with a name and no criteria.
struct RubricService {

    /// A rubric flattened out of SwiftData, so the network call does not carry a
    /// `@Model` reference across an isolation boundary.
    struct Snapshot: Sendable {
        let id: UUID
        let name: String
        let source: String
        let body: String?
        let totalMarks: Int?
        let items: [Item]

        struct Item: Sendable, Encodable {
            let code: String?
            let name: String
            let marks: Int?
            let guidance: String?
        }
    }

    enum Failure: LocalizedError, Equatable {
        case offline
        case unavailable
        /// The plan's rubrics are used up. Saving again will not help until
        /// one is deleted, so this must not read like a sync that failed.
        case planLimit
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .offline:
                "Saved on this phone only. Save it again when you're online to keep it in your account."
            case .unavailable:
                "Saved on this phone only. Save it again to keep it in your account."
            case .planLimit:
                // No number, for the reason `PlanService` gives for tasks:
                // Free keeps 3 and Plus 5, and a literal would be wrong for one.
                "That's as many synced rubrics as your plan keeps. This one is saved on your phone "
                + "only: delete one and save it again, or move up a plan."
            case .rejected(let why):
                why
            }
        }
    }

    private struct Params: Encodable, Sendable {
        let p_id: String
        let p_name: String
        let p_source: String
        let p_body: String?
        let p_total_marks: Int?
        let p_items: [Snapshot.Item]
    }

    private let client: SupabaseClient?
    private let log: @Sendable (String) -> Void

    init(client: SupabaseClient? = Backend.shared, log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.client = client
        self.log = log
    }

    func save(_ snapshot: Snapshot) async throws {
        guard let client else { throw Failure.unavailable }

        let params = Params(
            p_id: snapshot.id.uuidString,
            p_name: snapshot.name,
            p_source: snapshot.source,
            p_body: snapshot.body,
            p_total_marks: snapshot.totalMarks,
            p_items: snapshot.items
        )

        do {
            try await client.rpc("upsert_rubric", params: params).execute()
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? Failure.offline
                : Failure.unavailable
        } catch let error as PostgrestError where Self.isPlanLimit(error) {
            throw Failure.planLimit
        } catch {
            // Record the operation only: backend error details may include
            // student content. Preserve the existing user-facing failure.
            log("[Albus] rubric sync failed")
            throw Failure.unavailable
        }
    }

    /// `RUBRIC_PLAN_LIMIT`, raised as Q0011 by `assert_rubric_limits` when a
    /// new rubric would pass the plan's limit. Read by its code, never by its
    /// message text.
    static func isPlanLimit(_ error: PostgrestError) -> Bool {
        error.code == "Q0011"
    }

    /// Deleting is a plain DELETE: RLS scopes it to the owner, and the cascade
    /// takes the criteria with it.
    func delete(id: UUID) async throws {
        guard let client else { throw Failure.unavailable }
        do {
            try await client.from("rubrics").delete().eq("id", value: id.uuidString).execute()
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? Failure.offline
                : Failure.unavailable
        } catch {
            log("[Albus] rubric delete failed")
            throw Failure.unavailable
        }
    }
}

extension Rubric {
    /// Flattened on the main actor, where the model lives.
    @MainActor
    var snapshot: RubricService.Snapshot {
        RubricService.Snapshot(
            id: id,
            name: name,
            source: source,
            body: body,
            totalMarks: totalMarks,
            items: sortedItems.map {
                .init(code: $0.code, name: $0.name, marks: $0.marks, guidance: $0.guidance)
            }
        )
    }
}
