import Foundation
import SwiftData

/// Serializes remote mutations of each rubric so an earlier save cannot land
/// after a confirmed delete. Clearing an account invalidates queued operations.
@MainActor
enum RubricRemoteWrites {
    private static var tails: [UUID: (UUID, Task<Void, Never>)] = [:]
    private(set) static var generation = UUID()

    @discardableResult
    static func enqueue(id: UUID, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = tails[id]?.1
        let token = UUID()
        let epoch = generation
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled, generation == epoch else { return }
            await operation()
            if tails[id]?.0 == token { tails.removeValue(forKey: id) }
        }
        tails[id] = (token, task)
        return task
    }

    static func clear() {
        generation = UUID()
        for (_, task) in tails.values { task.cancel() }
        tails.removeAll()
    }
}

@MainActor
enum PendingRubricDeletions {
    static let key = "albus.pendingRubricDeletions"
    private static var generation = UUID()
    private static var tokens: [UUID: UUID] = [:]

    struct Receipt: Equatable {
        let id: UUID
        let token: UUID
        let generation: UUID
    }

    static func all(defaults: UserDefaults = .standard) -> [UUID] {
        (defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))
    }

    @discardableResult
    static func record(_ id: UUID, defaults: UserDefaults = .standard) -> Receipt {
        var ids = all(defaults: defaults)
        if !ids.contains(id) { ids.append(id) }
        defaults.set(ids.map(\.uuidString), forKey: key)
        let receipt = Receipt(id: id, token: UUID(), generation: generation)
        tokens[id] = receipt.token
        return receipt
    }

    static func contains(_ receipt: Receipt, defaults: UserDefaults = .standard) -> Bool {
        receipt.generation == generation && tokens[receipt.id] == receipt.token
            && all(defaults: defaults).contains(receipt.id)
    }

    static func acknowledge(_ receipt: Receipt, defaults: UserDefaults = .standard) {
        guard contains(receipt, defaults: defaults) else { return }
        cancel(receipt.id, defaults: defaults)
    }

    static func cancel(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(all(defaults: defaults).filter { $0 != id }.map(\.uuidString), forKey: key)
        tokens.removeValue(forKey: id)
    }

    static func clear(defaults: UserDefaults = .standard) {
        generation = UUID()
        tokens.removeAll()
        defaults.removeObject(forKey: key)
        RubricRemoteWrites.clear()
    }

    static func flush(context: ModelContext, defaults: UserDefaults = .standard,
                      deleteRemote: @escaping @MainActor (UUID) async throws -> Void = {
                          try await RubricService().delete(id: $0)
                      }) async {
        var tasks: [Task<Void, Never>] = []
        for id in all(defaults: defaults) {
            let token = tokens[id] ?? UUID()
            tokens[id] = token
            let receipt = Receipt(id: id, token: token, generation: generation)
            tasks.append(RubricRemoteWrites.enqueue(id: id) {
                guard contains(receipt, defaults: defaults) else { return }
                do {
                    // Complete a local deletion interrupted after its receipt
                    // was persisted but before SwiftData committed.
                    for rubric in try context.fetch(FetchDescriptor<Rubric>(predicate: #Predicate { $0.id == id })) {
                        context.delete(rubric)
                    }
                    try context.save()
                    try await deleteRemote(id)
                    acknowledge(receipt, defaults: defaults)
                } catch {
                    // Keep this receipt for the next launch/foreground retry.
                }
            })
        }
        for task in tasks { await task.value }
    }
}
