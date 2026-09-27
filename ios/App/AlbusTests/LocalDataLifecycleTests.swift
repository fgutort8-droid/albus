import Foundation
import SwiftData
import Testing
@testable import Albus

@MainActor
@Suite("Local data lifecycle", .serialized)
struct LocalDataLifecycleTests {
    @Test("rubric deletion records a durable remote retry")
    func rubricDeletionHasReceipt() async throws {
        let key = "albus.pendingRubricDeletions"
        let name = "albus.rubric.receipt.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let context = ModelContext(try ModelContainer(for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let rubric = Rubric(name: "Synthetic deletion fixture")
        let id = rubric.id
        context.insert(rubric)
        try context.save()
        let retry = RubricWriter.delete(rubric, context: context, defaults: defaults,
            deleteRemote: { _ in throw URLError(.notConnectedToInternet) })
        await retry?.value
        #expect((defaults.stringArray(forKey: key) ?? []).contains(id.uuidString))
        #expect(try context.fetchCount(FetchDescriptor<Rubric>()) == 0)
    }

    @Test("confirmed account cleanup includes its quarantined store copies")
    func quarantineCleanup() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("albus-recovery-test-\(UUID())")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("fixture.store")
        let config = ModelConfiguration(schema: AlbusSchema.schema, url: url)
        let context = ModelContext(try ModelContainer(for: AlbusSchema.schema, configurations: config))
        let copies = ["", "-wal", "-shm"].map {
            URL(fileURLWithPath: url.path + ".corrupt-2026-09-25T10-00-00Z" + $0)
        }
        for copy in copies { try Data("Synthetic private data".utf8).write(to: copy) }
        let unrelated = dir.appendingPathComponent("unrelated.store.corrupt-2026-09-25T10-00-00Z")
        try Data("Unrelated fixture".utf8).write(to: unrelated)
        let defaults = UserDefaults(suiteName: "albus.recovery.test.\(UUID())")!
        try AccountLocalData.erase(context: context, preferences: Preferences(defaults: defaults), defaults: defaults)
        #expect(copies.allSatisfy { !fm.fileExists(atPath: $0.path) })
        #expect(fm.fileExists(atPath: unrelated.path))
    }

    @Test("offline receipt retries without dropping a concurrently recorded deletion")
    func retryReceipt() async throws {
        let name = "albus.outbox.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let context = ModelContext(try ModelContainer(for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let id = UUID()
        PendingRubricDeletions.record(id, defaults: defaults)
        await PendingRubricDeletions.flush(context: context, defaults: defaults) { _ in
            throw URLError(.notConnectedToInternet)
        }
        #expect(PendingRubricDeletions.all(defaults: defaults) == [id])
        let second = UUID()
        await PendingRubricDeletions.flush(context: context, defaults: defaults) { _ in
            PendingRubricDeletions.record(second, defaults: defaults)
        }
        #expect(PendingRubricDeletions.all(defaults: defaults) == [second])
        await PendingRubricDeletions.flush(context: context, defaults: defaults) { _ in }
        #expect(PendingRubricDeletions.all(defaults: defaults).isEmpty)
    }

    @Test("an old completion cannot clear a newer receipt or account generation")
    func receiptGeneration() {
        let name = "albus.outbox.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let id = UUID()
        let old = PendingRubricDeletions.record(id, defaults: defaults)
        let newer = PendingRubricDeletions.record(id, defaults: defaults)
        PendingRubricDeletions.acknowledge(old, defaults: defaults)
        #expect(PendingRubricDeletions.contains(newer, defaults: defaults))
        PendingRubricDeletions.clear(defaults: defaults)
        let current = PendingRubricDeletions.record(id, defaults: defaults)
        PendingRubricDeletions.acknowledge(newer, defaults: defaults)
        #expect(PendingRubricDeletions.contains(current, defaults: defaults))
        PendingRubricDeletions.cancel(id, defaults: defaults)
    }

    @Test("queued deletion waits for the preceding remote save")
    func orderedWrites() async {
        let id = UUID()
        var events: [Int] = []
        RubricRemoteWrites.enqueue(id: id) {
            events.append(1)
            await Task.yield()
            events.append(2)
        }
        let final = RubricRemoteWrites.enqueue(id: id) { events.append(3) }
        await final.value
        #expect(events == [1, 2, 3])
    }

    @Test("interrupted local deletion is completed before its remote retry")
    func interruptedDeletion() async throws {
        let name = "albus.outbox.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let context = ModelContext(try ModelContainer(for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let rubric = Rubric(name: "Synthetic interrupted deletion")
        context.insert(rubric)
        try context.save()
        // Simulate a persisted receipt loaded after restarting the app.
        defaults.set([rubric.id.uuidString], forKey: PendingRubricDeletions.key)
        var attempted = false
        await PendingRubricDeletions.flush(context: context, defaults: defaults) { _ in
            attempted = true
            let remaining = try context.fetchCount(FetchDescriptor<Rubric>())
            #expect(remaining == 0)
        }
        #expect(attempted)
        #expect(PendingRubricDeletions.all(defaults: defaults).isEmpty)
    }

    @Test("quarantine cleanup fails closed for an unexpected directory")
    func quarantineDirectory() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("albus-quarantine-test-\(UUID())")
        let store = dir.appendingPathComponent("fixture.store")
        let unexpected = URL(fileURLWithPath: store.path + ".corrupt-2026-09-25T10-00-00Z")
        try fm.createDirectory(at: unexpected, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let child = unexpected.appendingPathComponent("keep.txt")
        try Data("Synthetic retained fixture".utf8).write(to: child)
        #expect(throws: (any Error).self) { try AccountLocalData.removeQuarantinedStores(at: store) }
        #expect(fm.fileExists(atPath: child.path))
    }


    @Test("memory fallback cleanup includes original files left by an interrupted quarantine")
    func fallbackOriginalFiles() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("albus-fallback-test-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.store")
        let originals = ["", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
        for file in originals { try Data("Synthetic retained store".utf8).write(to: file) }
        // These are the paths a failed rename leaves behind.
        let previous = AccountLocalData.recoveryStoreURL
        AccountLocalData.recoveryStoreURL = url
        defer { AccountLocalData.recoveryStoreURL = previous }
        let context = ModelContext(try ModelContainer(for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)))
        let name = "albus.fallback.cleanup.test.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try AccountLocalData.erase(context: context, preferences: Preferences(defaults: defaults), defaults: defaults)
        #expect(originals.allSatisfy { !fm.fileExists(atPath: $0.path) })
    }

}
