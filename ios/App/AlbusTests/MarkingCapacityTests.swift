import Foundation
import Supabase
import Testing
@testable import Albus

/// The app-wide AI budget is small on purpose, and while few students pay it
/// is the daily floor: about five rubric markings a day between everyone on a
/// paid plan or a trial. Past it the server answers `GLOBAL_CAPACITY_REACHED`,
/// before reserving anything.
///
/// That used to reach the student as "Albus couldn't finish marking that. Try
/// again with the same work and settings." Trying again meets the same refusal
/// until the day's spending has aged out, and nothing told a student who had
/// done nothing wrong that it was not their work or their connection. Found in
/// the pre-submission audit of November 2026.
@Suite("Marking at capacity")
struct MarkingCapacityTests {

    private func serverError(_ code: String, status: Int) -> FunctionsError {
        let data = try! JSONSerialization.data(withJSONObject: [
            "error": code, "message": "Albus is at capacity right now. Try again shortly.",
        ])
        return .httpError(code: status, data: data)
    }

    @Test("the server being at capacity is its own refusal, not a generic failure")
    func capacityIsNamed() {
        let failure = GradingService.translate(serverError("GLOBAL_CAPACITY_REACHED", status: 503))
        #expect(failure == .atCapacity)
        #expect(failure != .unavailable)
    }

    @Test("it says nothing was marked, nothing was used, and to come back later")
    func capacitySaysWhatHappened() {
        let text = GradingService.Failure.atCapacity.errorDescription ?? ""
        #expect(text.contains("at capacity"))
        #expect(text.contains("wasn't marked"))
        #expect(text.contains("none of your markings was used"))
        #expect(text.contains("later"))
        // Not the generic sentence, whose advice is to send it again now.
        #expect(text != GradingService.Failure.unavailable.errorDescription)
    }

    /// A subscription does not buy the app more capacity, so this must never
    /// open the plans.
    @Test("being at capacity is never answered with a price")
    func capacityIsNotAPaywall() {
        #expect(GradingService.Failure.atCapacity.isAnswerableByUpgrading == false)
    }

    /// Any other 503 is still the generic failure: only the named code may
    /// promise that none of the student's markings was used.
    @Test("an unnamed server failure makes no promise about the allowance")
    func otherFailuresStayGeneric() {
        #expect(GradingService.translate(serverError("INTERNAL_ERROR", status: 503)) == .unavailable)
        #expect(GradingService.translate(serverError("UPSTREAM_UNAVAILABLE", status: 503)) == .unavailable)
    }
}
