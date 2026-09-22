import Foundation
import SwiftData
import Testing
@testable import Albus

@MainActor
@Suite("Account deletion")
struct AccountDeletionTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "albus.deletion.tests.\(UUID())")!
    }

    @Test("offline refusal leaves the cache and session untouched")
    func offline() async {
        let deletion = AccountDeletion(defaults: defaults())
        var cleared = false
        var signedOut = false
        let result = await deletion.perform(
            deleteRemote: { throw URLError(.notConnectedToInternet) },
            clearLocal: { cleared = true }, signOut: { signedOut = true })
        #expect(!result && !cleared && !signedOut)
        #expect(!deletion.requiresCleanup && !deletion.isBusy)
        #expect(deletion.errorMessage?.contains("offline") == true)
    }

    @Test("confirmed removal clears local data before signing out")
    func successfulOrder() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        var steps: [String] = []
        let result = await deletion.perform(
            deleteRemote: { steps.append("remote") },
            clearLocal: {
                #expect(deletion.requiresCleanup)
                steps.append("local")
            }, signOut: { steps.append("signOut") })
        #expect(result)
        #expect(steps == ["remote", "local", "signOut"])
        #expect(!AccountDeletion(defaults: store).requiresCleanup)
    }

    @Test("restart retries incomplete cleanup without removing the account again")
    func cleanupRecovery() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        var removals = 0
        var signOuts = 0
        let result = await deletion.perform(
            deleteRemote: { removals += 1 },
            clearLocal: { throw URLError(.cannotWriteToFile) },
            signOut: { signOuts += 1 })
        #expect(!result && signOuts == 0)
        let restarted = AccountDeletion(defaults: store)
        #expect(restarted.requiresCleanup)
        #expect(await restarted.perform(
            deleteRemote: { removals += 1 }, clearLocal: {},
            signOut: { signOuts += 1 }))
        #expect(removals == 1 && signOuts == 1)
    }

    @Test("sign-out failure keeps recovery gated and does not repeat the RPC")
    func signOutRecovery() async {
        let deletion = AccountDeletion(defaults: defaults())
        var removals = 0
        #expect(await !deletion.perform(deleteRemote: { removals += 1 }, clearLocal: {},
            signOut: { throw URLError(.cannotConnectToHost) }))
        #expect(deletion.requiresCleanup)
        #expect(await deletion.perform(deleteRemote: { removals += 1 }, clearLocal: {}, signOut: {}))
        #expect(removals == 1)
    }

    @Test("a second tap cannot start another request")
    func duplicateTap() async {
        let deletion = AccountDeletion(defaults: defaults())
        var calls = 0
        var duplicate = true
        let result = await deletion.perform(deleteRemote: {
            calls += 1
            duplicate = await deletion.perform(deleteRemote: { calls += 1 }, clearLocal: {}, signOut: {})
        }, clearLocal: {}, signOut: {})
        #expect(result && !duplicate)
        #expect(calls == 1)
    }

    @Test("local cleanup removes saved and unsaved work and restarts onboarding")
    func localCleanup() throws {
        let container = try ModelContainer(for: AlbusSchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        SeedData.populate(context)
        let rubric = Rubric(name: "Private rubric", body: "Student instructions")
        context.insert(rubric)
        context.insert(RubricItem(name: "Evidence", ordinal: 0, rubric: rubric))
        context.insert(Grading(model: "test", inputChars: 100, feedback: "Student feedback"))
        context.insert(CompletionRecord(subjectCode: nil, taskType: "essay", estimatedMinutes: 30, actualMinutes: 25))
        try context.save()
        context.insert(Rubric(name: "Unsaved private rubric"))
        let preferences = Preferences(defaults: defaults())
        preferences.name = "A student"
        preferences.markOnboarded()
        #expect(try context.fetchCount(FetchDescriptor<Assignment>()) > 0)
        try AccountLocalData.erase(context: context, preferences: preferences, defaults: defaults())
        #expect(try context.fetchCount(FetchDescriptor<Assignment>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Course>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Subtask>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<PlanSessionRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<CompletionRecord>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Rubric>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<RubricItem>()) == 0)
        #expect(try context.fetchCount(FetchDescriptor<Grading>()) == 0)
        #expect(!preferences.hasOnboarded && preferences.name.isEmpty)
    }
}
