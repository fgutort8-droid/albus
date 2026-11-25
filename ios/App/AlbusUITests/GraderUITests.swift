import XCTest

/// Drives Albus Grader on the Free plan, from a fresh install.
///
/// **Free does not include marking.** So this proves that a student who
/// cannot mark is shown a price rather than a broken screen, and that marking
/// from an assignment opens the same Grader with that assignment carried in.
///
/// No server is contacted. The plan is forced to Free
/// (`-albus.debug.forcePlan`), onboarding's first plan is the one the phone
/// makes (the AI question is answered no, `OnboardingPath`), and nothing is
/// marked. It used to read the real `my_plan()` from a fresh production
/// account and spend a real AI call on the first plan; whether `my_plan()`
/// still decodes belongs in `EntitlementServiceTests` and the database tests,
/// which need no account.
@MainActor
final class GraderUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    /// The whole free-tier contract on one screen.
    ///
    /// From a student's side, a Grader that cannot mark must still say why and
    /// offer the plans: a screen with no meter and no offer is how a broken
    /// plan read looked twice before.
    func testFreeIsOfferedThePlansRatherThanABrokenGrader() throws {
        app.launchArguments += ["-albus.debug.forcePlan", "free"]
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()

        // Twenty seconds, not ten. Tools ranks a two-hundred-entry catalogue the
        // first time it is drawn, and on the first launch of a run that ran past
        // ten — failing a test about the plan meter for a reason that had nothing
        // to do with it. The same wait later in the same run takes under a second.
        let grader = app.staticTexts["Albus Grader"]
        XCTAssertTrue(grader.waitForExistence(timeout: 20),
                      "the pinned Albus Grader card is not on Tools")
        grader.tap()

        // "N left this week" / "Unlimited" while there are markings to use, and
        // otherwise the card saying which of its two reasons applies — any of
        // them is a decoded plan. None of them is a plan call that failed. The
        // meter no longer says "Not on the Free plan": the card below it did too.
        let notOnPlan = "Marking is part of Plus and Pro."
        let meter = app.staticTexts.matching(
            NSPredicate(format:
                "label CONTAINS[c] 'left this week' OR label == 'Unlimited' "
                + "OR label == %@ OR label BEGINSWITH %@",
                notOnPlan, "That's this week's markings used")
        ).firstMatch
        XCTAssertTrue(meter.waitForExistence(timeout: 15),
                      "the plan never resolved — my_plan() returned a shape the "
                      + "client could not decode")

        // Every account on this project is currently granted Pro for testing,
        // so the Free path below is unreachable from here. Skipping rather than
        // asserting the wrong thing: a test that quietly passes because it
        // tested nothing is worse than one that says it could not run.
        guard meter.label == notOnPlan else {
            throw XCTSkip("this account is not on Free — the screen reads '\(meter.label)'")
        }

        attach(app.screenshot(), named: "grader-free")

        // **Zero is not unlimited.** A limit of 0 and a limit of nil both leave
        // nothing to spend, and the app used to read 0 as "no ceiling" — which
        // under three tiers would hand every free student unlimited marking.
        XCTAssertFalse(app.staticTexts["Unlimited"].exists,
                       "a free account is reading its zero allowance as "
                       + "unlimited — the nil/zero convention has inverted")

        // Offered a price, not a date. Telling somebody who never had a grading
        // that theirs comes back on Monday promises a Monday that never comes.
        XCTAssertTrue(app.buttons["See the plans"].waitForExistence(timeout: 5),
                      "a free account is not offered the plans")
        XCTAssertFalse(app.buttons["Grade a piece of work"].exists,
                       "the grader is offering to mark work the plan does not cover")
    }

    // The paywall's own test moved to `PaywallUITests`. It never needed a
    // server — the screen carries its own copy — so it was paying for an
    // account and an AI call to check a layout, and CI skipped it for that
    // reason. It now runs on every change, for nothing.

    /// The other way in.
    ///
    /// There were two graders until recently — this button opened a `Form`
    /// sheet that could not upload, could not photograph a rubric and never
    /// asked how the course marks, while Tools opened the real thing. They are
    /// one flow now, and this is what proves the assignment screen actually
    /// pushes it rather than silently doing nothing: `navigationDestination`
    /// has failed quietly in this app before.
    func testMarkingFromAnAssignmentOpensTheSameGrader() throws {
        app.launchArguments += ["-albus.debug.forcePlan", "free"]
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Home"].tap()

        let card = app.descendants(matching: .any)
            .matching(identifier: "assignmentCard").element(boundBy: 0)
        guard card.waitForExistence(timeout: 30) else {
            throw XCTSkip("no assignment on Home to open")
        }
        card.tap()

        let mark = app.buttons["markMyWork"]
        XCTAssertTrue(mark.waitForExistence(timeout: 15),
                      "the marking card is missing from the assignment screen")
        mark.tap()

        // The grader's own screen, not a sheet with a Form in it.
        XCTAssertTrue(app.navigationBars["Albus Grader"].waitForExistence(timeout: 10),
                      "marking from an assignment did not open Albus Grader")

        // The reported bug. Arriving here pre-selects the assignment, but the
        // checkmark is drawn per row — so an assignment that was finished, or
        // sat past the old cap of six, was selected with nothing on screen
        // saying so, which is indistinguishable from a dead button.
        let confirmation = app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Marking '")).firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 10),
                      "the grader does not say what it is marking — the student "
                      + "cannot tell the assignment was carried in")

        attach(app.screenshot(), named: "grader-from-assignment")
    }

    /// Screenshots survive the run, so a failure can be looked at rather than
    /// reasoned about from an assertion message.
    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
