import Foundation
import Testing
@testable import Albus

/// The wording of the redesigned problem and empty states, where it is worked
/// out rather than written down: counts, durations, dates, and which of the
/// deletion failures may promise that nothing was deleted.
@MainActor
struct ErrorStatesTests {

    @Test("durations read as hours and minutes")
    func durations() {
        #expect(HomeScreen.duration(40) == "40 min")
        #expect(HomeScreen.duration(60) == "1 h")
        #expect(HomeScreen.duration(85) == "1 h 25")
    }

    @Test("the task meter names the plan, its limit and where the tasks are")
    func meterSentence() {
        #expect(HomeScreen.meterSentence(plan: "Free", limit: 3, here: 3, elsewhere: 0)
                == "Free keeps 3 open at once. Finish one to add the next.")
        #expect(HomeScreen.meterSentence(plan: "Free", limit: 3, here: 1, elsewhere: 2)
                == "Only 1 of them is on this phone. The other 2 were made on another phone, "
                 + "or before Albus was reinstalled. Free keeps 3 open at once.")
        #expect(HomeScreen.meterSentence(plan: "Plus", limit: 10, here: 0, elsewhere: 1)
                == "It isn't on this phone. It was made on another phone, or before Albus was "
                 + "reinstalled. Plus keeps 10 open at once.")
        #expect(HomeScreen.meterSentence(plan: "Free", limit: 3, here: 0, elsewhere: 3)
                .hasPrefix("None of them are on this phone. They were made"))
    }

    @Test("a deadline this week is a weekday, later ones a date")
    func dayNames() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 9)))
        let monday = try #require(Calendar.current.date(byAdding: .day, value: 4, to: now))
        let later = try #require(Calendar.current.date(byAdding: .day, value: 12, to: now))
        #expect(TaskDetailScreen.dayName(monday, now: now) == monday.formatted(.dateTime.weekday(.wide)))
        #expect(TaskDetailScreen.dayName(later, now: now) == later.formatted(.dateTime.day().month(.abbreviated)))
    }

    @Test("stale plan figures say when they were last confirmed")
    func staleFigures() throws {
        let now = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: 15)))
        let morning = try #require(Calendar.current.date(byAdding: .hour, value: -6, to: now))
        #expect(EntitlementRefreshNotice.sentence(lastCheckedAt: nil, now: now) == "Couldn't check your plan yet.")
        #expect(EntitlementRefreshNotice.sentence(lastCheckedAt: morning, now: now)
                == "As of \(morning.formatted(date: .omitted, time: .shortened)). Couldn't check your plan for changes.")
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "albus.error-states.tests.\(UUID())")!
    }

    @Test("a deletion that never left the phone says nothing was deleted")
    func unsentDeletion() async {
        let deletion = AccountDeletion(defaults: defaults())
        _ = await deletion.perform(reachServer: { throw URLError(.notConnectedToInternet) },
                                   deleteRemote: {}, clearLocal: {}, signOut: {})
        #expect(deletion.errorTitle == AccountDeletion.notDeleted)
        #expect(deletion.errorMessage?.contains("never left this phone") == true)
    }

    /// The request reached the server and the answer was lost: the account may
    /// already be gone, offline or not, so the card must not say it wasn't.
    @Test("a deletion whose answer was lost never claims nothing was deleted",
          arguments: [URLError.Code.notConnectedToInternet, .networkConnectionLost, .timedOut])
    func lostAnswer(code: URLError.Code) async {
        let deletion = AccountDeletion(defaults: defaults())
        _ = await deletion.perform(reachServer: {},
                                   deleteRemote: { throw URLError(code) },
                                   clearLocal: {}, signOut: {})
        #expect(deletion.errorTitle == "Albus didn't hear back")
        #expect(deletion.errorMessage?.contains("may already be deleted") == true)
        #expect(deletion.errorMessage?.contains("wasn't deleted") == false)
    }

    /// A lost answer left the request outstanding; a retry that then fails
    /// before asking again still cannot say the account was not deleted.
    @Test("a retry after a lost answer keeps saying the account may be deleted")
    func retryAfterLostAnswer() async {
        let store = defaults()
        let first = AccountDeletion(defaults: store)
        _ = await first.perform(reachServer: {}, deleteRemote: { throw URLError(.networkConnectionLost) },
                                clearLocal: {}, signOut: {})
        let retry = AccountDeletion(defaults: store)
        _ = await retry.perform(reachServer: { throw URLError(.notConnectedToInternet) },
                                deleteRemote: {}, clearLocal: {}, signOut: {})
        #expect(retry.errorTitle == "Albus didn't hear back")
    }

    /// An account this phone cannot reach is cleared from the phone only, so
    /// a cleanup that fails must not say the account itself was deleted.
    @Test("a failed cleanup claims a deletion only when the server confirmed one")
    func cleanupClaims() async {
        let confirmed = AccountDeletion(defaults: defaults())
        _ = await confirmed.perform(reachServer: {}, deleteRemote: {},
                                    clearLocal: { throw URLError(.cannotCreateFile) }, signOut: {})
        #expect(confirmed.errorMessage?.hasPrefix("Your account is deleted") == true)

        let unreachable = AccountDeletion(defaults: defaults())
        _ = await unreachable.perform(reachServer: { throw AccountUnreachable() }, deleteRemote: {},
                                      clearLocal: { throw URLError(.cannotCreateFile) }, signOut: {})
        #expect(unreachable.errorMessage == "This phone still holds some of your account.")
    }

    @Test("an empty file is not told it is blurred")
    func emptyFileAdvice() {
        #expect(WorkExtractor.Failure.empty.message(fromPhoto: false).contains("file"))
        #expect(WorkExtractor.Failure.empty.message(fromPhoto: true).contains("blurred"))
    }

    @Test("every marking failure has a title of its own")
    func markingHeadlines() {
        let failures: [GradingService.Failure] = [
            .offline, .tooFast, .atCapacity, .notSaved, .unusableResponse, .unavailable,
            .tooLong(600), .tooShort, .noRubric, .rejected("No."), .needsVerification,
            .paused, .fairUseReached,
        ]
        for failure in failures {
            #expect(!failure.headline.isEmpty)
            #expect(failure.headline != failure.errorDescription, "the title and sentence say different things")
        }
        #expect(GradingService.Failure.unusableResponse.errorDescription?.contains("costs nothing") == false)
    }
}
