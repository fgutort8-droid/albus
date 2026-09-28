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
        var requested = false
        var cleared = false
        var signedOut = false
        let result = await deletion.perform(
            confirmAccount: { throw URLError(.notConnectedToInternet) },
            deleteRemote: { requested = true },
            clearLocal: { cleared = true }, signOut: { signedOut = true })
        #expect(!result && !requested && !cleared && !signedOut)
        #expect(!deletion.requiresCleanup && !deletion.isBusy)
        #expect(deletion.errorMessage?.contains("offline") == true)
    }

    /// The reported bug: a failed offline attempt left the request mark set,
    /// and the mark keeps launch waiting for the server. Offline with an
    /// expired pass, that sent the student to set-up instead of their plans.
    @Test("an attempt that never left the phone leaves nothing outstanding",
          arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost, .cannotConnectToHost])
    func unsentAttemptLeavesNothingOutstanding(failure: URLError.Code) async {
        let store = defaults()
        let attempt = AccountDeletion(defaults: store)
        var requested = false
        #expect(await !attempt.perform(
            confirmAccount: { throw URLError(failure) },
            deleteRemote: { requested = true },
            clearLocal: {}, signOut: {}))
        #expect(!requested, "the question failed, so the deletion was never asked for")
        #expect(attempt.errorMessage != nil)

        let relaunched = AccountDeletion(defaults: store)
        #expect(!relaunched.hasUnansweredRequest, "launch opens straight onto the plans")
        // Nothing was asked, so a pass refused later is not read as a deletion.
        relaunched.adoptLostDeletion(credentialRejected: true)
        #expect(!relaunched.requiresCleanup)
    }

    @Test("an unanswered request outlives a retry that never left the phone")
    func earlierRequestOutlivesUnsentRetry() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        #expect(await !deletion.perform(
            confirmAccount: {}, deleteRemote: { throw URLError(.networkConnectionLost) },
            clearLocal: {}, signOut: {}))
        #expect(deletion.hasUnansweredRequest, "the first request may have been carried out")

        #expect(await !deletion.perform(
            confirmAccount: { throw URLError(.notConnectedToInternet) },
            deleteRemote: { Issue.record("never sent") },
            clearLocal: {}, signOut: {}))
        #expect(deletion.hasUnansweredRequest, "a retry that went nowhere answers nothing")

        let relaunched = AccountDeletion(defaults: store)
        relaunched.adoptLostDeletion(credentialRejected: true)
        #expect(relaunched.requiresCleanup)
    }

    @Test("an account already gone when asked about is cleared without a deletion request")
    func goneAtConfirmationFinishes() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        var requested = false
        var cleared = false
        #expect(await deletion.perform(
            confirmAccount: { throw AccountUnreachable() },
            deleteRemote: { requested = true },
            clearLocal: { cleared = true }, signOut: {}))
        #expect(!requested && cleared)
        #expect(!AccountDeletion(defaults: store).requiresCleanup)
        #expect(!AccountDeletion(defaults: store).hasUnansweredRequest)
    }

    @Test("a pass the server renews well after the request settles it")
    func renewalSettlesUnansweredRequest() async {
        let store = defaults()
        let asked = Date.now
        #expect(await !AccountDeletion(defaults: store).perform(
            confirmAccount: {}, deleteRemote: { throw URLError(.timedOut) },
            clearLocal: {}, signOut: {}))

        let relaunched = AccountDeletion(defaults: store)
        #expect(relaunched.hasUnansweredRequest)
        relaunched.accountOutlivedRequest(renewalBegan: asked.addingTimeInterval(AccountDeletion.settleAfter + 5))
        #expect(!relaunched.hasUnansweredRequest)
        #expect(!AccountDeletion(defaults: store).hasUnansweredRequest, "and it stays settled")
        #expect(store.object(forKey: "albus.accountDeletion.requestedAt") == nil)
        // Settled as "not deleted": a pass refused much later is some other story.
        relaunched.adoptLostDeletion(credentialRejected: true)
        #expect(!relaunched.requiresCleanup)
    }

    /// The server may still have been carrying out the deletion when it
    /// renewed the pass. If it then finishes, the pass is refused next time,
    /// and only the mark lets that refusal clean the phone.
    @Test("a renewal soon after the request settles nothing")
    func earlyRenewalSettlesNothing() async {
        let store = defaults()
        let asked = Date.now
        #expect(await !AccountDeletion(defaults: store).perform(
            confirmAccount: {}, deleteRemote: { throw URLError(.networkConnectionLost) },
            clearLocal: {}, signOut: {}))

        let relaunched = AccountDeletion(defaults: store)
        relaunched.accountOutlivedRequest(renewalBegan: asked.addingTimeInterval(90))
        #expect(relaunched.hasUnansweredRequest)
        relaunched.adoptLostDeletion(credentialRejected: true)
        #expect(relaunched.requiresCleanup, "the deletion finished after all, and the phone is cleaned")
    }

    @Test("a mark from before requests carried their time waits from the first renewal")
    func undatedMarkWaits() {
        let store = defaults()
        store.set(true, forKey: "albus.accountDeletion.requested")
        let deletion = AccountDeletion(defaults: store)
        let first = Date.now
        deletion.accountOutlivedRequest(renewalBegan: first)
        #expect(deletion.hasUnansweredRequest, "no time to measure from: the clock starts now")
        deletion.accountOutlivedRequest(renewalBegan: first.addingTimeInterval(60))
        #expect(deletion.hasUnansweredRequest)
        deletion.accountOutlivedRequest(renewalBegan: first.addingTimeInterval(AccountDeletion.settleAfter + 1))
        #expect(!deletion.hasUnansweredRequest)
    }

    @Test("a request in flight is never settled from under it")
    func settlingWaitsForInFlightRequest() async {
        let deletion = AccountDeletion(defaults: defaults())
        #expect(await !deletion.perform(
            confirmAccount: {},
            deleteRemote: {
                deletion.accountOutlivedRequest(renewalBegan: .now.addingTimeInterval(3600))
                throw URLError(.networkConnectionLost)
            },
            clearLocal: {}, signOut: {}))
        #expect(deletion.hasUnansweredRequest)
    }

    @Test("confirmed removal clears local data before signing out")
    func successfulOrder() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        var steps: [String] = []
        let result = await deletion.perform(
            confirmAccount: {}, deleteRemote: { steps.append("remote") },
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
            confirmAccount: {}, deleteRemote: { removals += 1 },
            clearLocal: { throw URLError(.cannotWriteToFile) },
            signOut: { signOuts += 1 })
        #expect(!result && signOuts == 0)
        let restarted = AccountDeletion(defaults: store)
        #expect(restarted.requiresCleanup)
        #expect(await restarted.perform(
            confirmAccount: {}, deleteRemote: { removals += 1 }, clearLocal: {},
            signOut: { signOuts += 1 }))
        #expect(removals == 1 && signOuts == 1)
    }

    @Test("sign-out failure keeps recovery gated and does not repeat the RPC")
    func signOutRecovery() async {
        let deletion = AccountDeletion(defaults: defaults())
        var removals = 0
        #expect(await !deletion.perform(confirmAccount: {}, deleteRemote: { removals += 1 }, clearLocal: {},
            signOut: { throw URLError(.cannotConnectToHost) }))
        #expect(deletion.requiresCleanup)
        #expect(await deletion.perform(confirmAccount: {}, deleteRemote: { removals += 1 }, clearLocal: {}, signOut: {}))
        #expect(removals == 1)
    }

    @Test("a second tap cannot start another request")
    func duplicateTap() async {
        let deletion = AccountDeletion(defaults: defaults())
        var calls = 0
        var duplicate = true
        let result = await deletion.perform(confirmAccount: {}, deleteRemote: {
            calls += 1
            duplicate = await deletion.perform(confirmAccount: {}, deleteRemote: { calls += 1 }, clearLocal: {}, signOut: {})
        }, clearLocal: {}, signOut: {})
        #expect(result && !duplicate)
        #expect(calls == 1)
    }

    @Test("an account that can no longer be reached is treated as deleted")
    func unreachableAccountFinishes() async {
        let store = defaults()
        let deletion = AccountDeletion(defaults: store)
        var cleared = false
        var signedOut = false
        let result = await deletion.perform(
            confirmAccount: {}, deleteRemote: { throw AccountUnreachable() },
            clearLocal: { cleared = true }, signOut: { signedOut = true })
        #expect(result && cleared && signedOut)
        #expect(deletion.errorMessage == nil)
        #expect(!AccountDeletion(defaults: store).requiresCleanup)
    }

    /// The whole point of the request mark: the server committed, the answer
    /// was lost, and the student force-quit rather than tapping Try again.
    @Test("a lost answer plus a refused credential finishes the deletion on the next launch")
    func lostAnswerIsAdoptedAtLaunch() async {
        let store = defaults()
        let attempt = AccountDeletion(defaults: store)
        #expect(await !attempt.perform(
            confirmAccount: {}, deleteRemote: { throw URLError(.networkConnectionLost) },
            clearLocal: {}, signOut: {}))
        #expect(!attempt.requiresCleanup)
        #expect(attempt.hasUnansweredRequest, "the account answered, so the request went out")

        let relaunched = AccountDeletion(defaults: store)
        relaunched.adoptLostDeletion(credentialRejected: true)
        #expect(relaunched.requiresCleanup)

        var removals = 0
        var cleared = false
        #expect(await relaunched.perform(
            confirmAccount: {}, deleteRemote: { removals += 1 }, clearLocal: { cleared = true }, signOut: {}))
        // The account is already gone; asking again would fail and strand them.
        #expect(removals == 0 && cleared)
        #expect(!AccountDeletion(defaults: store).requiresCleanup)
    }

    @Test("a phone with no signal never has its work erased")
    func offlineIsNotEvidence() async {
        let store = defaults()
        let attempt = AccountDeletion(defaults: store)
        // The signal went between the question and the request: the request
        // may have gone out, so it is outstanding, but it proves nothing.
        #expect(await !attempt.perform(
            confirmAccount: {}, deleteRemote: { throw URLError(.notConnectedToInternet) },
            clearLocal: {}, signOut: {}))
        #expect(attempt.hasUnansweredRequest)

        let relaunched = AccountDeletion(defaults: store)
        relaunched.adoptLostDeletion(credentialRejected: false)
        #expect(!relaunched.requiresCleanup)
    }

    @Test("a refused credential erases nothing when no deletion was ever asked for")
    func expiredSessionAloneErasesNothing() {
        let deletion = AccountDeletion(defaults: defaults())
        deletion.adoptLostDeletion(credentialRejected: true)
        #expect(!deletion.requiresCleanup)
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
