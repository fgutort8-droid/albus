import Foundation
import SwiftData

/// Saving a rubric, in one place.
///
/// Two screens create rubrics — the Rubrics tab and the add-assignment sheet —
/// and they must produce the same thing. A rubric written while adding an
/// assignment is a real saved rubric, reusable next time, not a one-off; that is
/// only true if both paths run this code.
@MainActor
enum RubricWriter {

    /// Writes the draft locally and kicks off the server sync.
    ///
    /// Local first, deliberately: local is the source of truth for the student's
    /// own screens, and the server copy exists so the breakdown and grading
    /// endpoints can read the rubric by id. A failed sync leaves a rubric that
    /// still works offline and still plans work — it just cannot be graded
    /// against until it lands.
    ///
    /// Returns the rubric's id, or nil if the local write failed.
    @discardableResult
    static func commit(_ draft: RubricDraft, context: ModelContext,
                       onSyncFailure: @escaping (String) -> Void = { _ in }) -> UUID? {
        let rubric: Rubric

        // Hoisted: #Predicate cannot reach through a struct, so `draft.id` has
        // to be a plain captured value rather than a key path.
        let draftID = draft.id
        let existing = try? context.fetch(
            FetchDescriptor<Rubric>(predicate: #Predicate { $0.id == draftID })
        ).first

        if let found = existing ?? nil {
            rubric = found
            rubric.name = draft.trimmedName
            rubric.body = draft.trimmedBody
            rubric.totalMarks = draft.totalMarks
            rubric.updatedAt = .now
            // Replace wholesale rather than diffing: a rubric is a handful of
            // rows and the whole thing is being saved anyway.
            for item in rubric.items { context.delete(item) }
        } else {
            rubric = Rubric(id: draft.id, name: draft.trimmedName,
                            body: draft.trimmedBody, totalMarks: draft.totalMarks)
            context.insert(rubric)
        }

        for (index, row) in draft.usableItems.enumerated() {
            context.insert(RubricItem(
                code: row.trimmedCode, name: row.trimmedName,
                marks: row.marks, guidance: row.trimmedGuidance,
                ordinal: index, rubric: rubric
            ))
        }

        do {
            try context.save()
        } catch {
            print("[Albus] rubric save failed")
            onSyncFailure("Couldn't save that rubric.")
            return nil
        }

        sync(rubric, onFailure: onSyncFailure)
        return rubric.id
    }

    static func duplicate(_ rubric: Rubric, context: ModelContext,
                          onSyncFailure: @escaping (String) -> Void = { _ in }) {
        let copy = Rubric(name: "\(rubric.name) copy", body: rubric.body,
                          totalMarks: rubric.totalMarks)
        context.insert(copy)
        for item in rubric.sortedItems {
            context.insert(RubricItem(code: item.code, name: item.name, marks: item.marks,
                                      guidance: item.guidance, ordinal: item.ordinal,
                                      rubric: copy))
        }
        do { try context.save() } catch {
            print("[Albus] rubric duplicate failed")
            onSyncFailure("Couldn't save that rubric.")
            return
        }
        sync(copy, onFailure: onSyncFailure)
    }

    @discardableResult
    static func delete(_ rubric: Rubric, context: ModelContext,
                       defaults: UserDefaults = .standard,
                       deleteRemote: @escaping @MainActor (UUID) async throws -> Void = {
                           try await RubricService().delete(id: $0)
                       },
                       onFailure: @escaping (String) -> Void = { _ in }) -> Task<Void, Never>? {
        let id = rubric.id
        let alreadyPending = PendingRubricDeletions.all(defaults: defaults).contains(id)
        let receipt = PendingRubricDeletions.record(id, defaults: defaults)
        context.delete(rubric)
        do {
            try context.save()
        } catch {
            context.rollback()
            if !alreadyPending { PendingRubricDeletions.acknowledge(receipt, defaults: defaults) }
            onFailure("Couldn't delete that rubric. Please try again.")
            return nil
        }
        return Task { await PendingRubricDeletions.flush(context: context, defaults: defaults, deleteRemote: deleteRemote) }
    }

    private static func sync(_ rubric: Rubric, onFailure: @escaping (String) -> Void) {
        let snapshot = rubric.snapshot
        PendingRubricDeletions.cancel(snapshot.id)
        RubricRemoteWrites.enqueue(id: snapshot.id) {
            do {
                try await RubricService().save(snapshot)
            } catch {
                onFailure((error as? LocalizedError)?.errorDescription
                          ?? "Couldn't sync this rubric. It's saved on your phone.")
            }
        }
    }
}
