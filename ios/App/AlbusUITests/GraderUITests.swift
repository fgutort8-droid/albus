import XCTest

/// Drives Albus Grader against the real backend, from a fresh account.
///
/// **A fresh account is a Free account, and Free does not include marking.**
/// That reframes what this file is for. It used to prove the meter named the
/// right window; now it proves the more basic thing underneath — that the plan
/// call still returns a shape the client can decode, and that a student who
/// cannot mark is shown a price rather than a broken screen.
///
/// It is still the only test that exercises the real RPC. A unit test on
/// `Allowance` proves the arithmetic; only this proves `my_plan()` still
/// returns what that arithmetic is built on, which is where the last three bugs
/// in this feature lived.
///
/// Nothing here spends a grading. Marking is an Opus call and it is now a paid
/// feature, so a free account is refused before any model runs.
@MainActor
final class GraderUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    /// The whole free-tier contract on one screen.
    ///
    /// The failure this guards against is the plan call returning a shape the
    /// client cannot decode. From here that looks like a screen with no meter
    /// and no offer — which, before three tiers, is exactly how a changed RPC
    /// shape presented twice.
    func testFreeIsOfferedThePlansRatherThanABrokenGrader() throws {
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

        // "Not on the Free plan" / "N left this week" / "Unlimited" — any of the
        // three is a decoded plan. None of them is a plan call that failed.
        let meter = app.staticTexts.containing(
            NSPredicate(format:
                "label CONTAINS[c] 'left this week' OR label == 'Unlimited' "
                + "OR label CONTAINS[c] 'Not on the'")
        ).element
        XCTAssertTrue(meter.waitForExistence(timeout: 15),
                      "the plan meter never resolved — my_plan() returned a "
                      + "shape the client could not decode")

        // Every account on this project is currently granted Pro for testing,
        // so the Free path below is unreachable from here. Skipping rather than
        // asserting the wrong thing: a test that quietly passes because it
        // tested nothing is worse than one that says it could not run.
        guard meter.label.contains("Not on the") else {
            throw XCTSkip("this account is not on Free — the meter reads '\(meter.label)'")
        }

        attach(app.screenshot(), named: "grader-free")

        // **Zero is not unlimited.** A limit of 0 and a limit of nil both leave
        // nothing to spend, and the app used to read 0 as "no ceiling" — which
        // under three tiers would hand every free student unlimited marking.
        XCTAssertNotEqual(meter.label, "Unlimited",
                          "a free account is reading its zero allowance as "
                          + "unlimited — the nil/zero convention has inverted")

        // Offered a price, not a date. Telling somebody who never had a grading
        // that theirs comes back on Monday promises a Monday that never comes.
        XCTAssertTrue(app.buttons["See the plans"].waitForExistence(timeout: 5),
                      "a free account is not offered the plans")
        XCTAssertFalse(app.buttons["Grade a piece of work"].exists,
                       "the grader is offering to mark work the plan does not cover")
    }

    /// The paywall itself. The only test that renders it.
    func testThePaywallShowsThreePlansAndMarksTheCurrentOne() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()
        // Same twenty seconds as the test above: Tools ranks the whole catalogue
        // the first time it is drawn, and tapping into a screen that has not
        // finished laying out fails for a reason unrelated to the paywall.
        let grader = app.staticTexts["Albus Grader"]
        XCTAssertTrue(grader.waitForExistence(timeout: 20),
                      "the pinned Albus Grader card is not on Tools")
        grader.tap()

        let seePlans = app.buttons["See the plans"]
        guard seePlans.waitForExistence(timeout: 15) else {
            throw XCTSkip("this account can mark — the plans are not being offered")
        }
        seePlans.tap()

        // The intro animation runs first; a tap skips it.
        let skip = app.otherElements["Skip the introduction"]
        if skip.waitForExistence(timeout: 3) { skip.tap() }

        // **Visible, not merely present.** This is the assertion that matters
        // and the one that was missing: the three cards sat below the fold
        // behind the purchase bar for the first version of this screen, and
        // `waitForExistence` was perfectly happy — an element that exists
        // somewhere nobody can see it still exists. A student could not compare
        // three prices on the screen whose only job is comparing three prices.
        let window = app.windows.element(boundBy: 0).frame
        for plan in ["Free", "Plus", "Pro"] {
            let card = app.buttons.containing(
                NSPredicate(format: "label BEGINSWITH %@", plan + ",")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 10),
                          "\(plan) is missing from the paywall")
            XCTAssertTrue(card.isHittable,
                          "\(plan) is on the paywall but not reachable — it is "
                          + "off-screen or behind something")
            XCTAssertTrue(window.contains(card.frame),
                          "\(plan)'s card is outside the visible window "
                          + "(\(card.frame) vs \(window)) — the student has to "
                          + "scroll to find out what the plans cost")
        }

        attach(app.screenshot(), named: "paywall-three-plans")

        // Prices, as a student reads them. A card with no price is not a plan.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '7.99'")).element.waitForExistence(timeout: 5),
                      "Plus has no price on the paywall")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '14.99'")).element.exists,
                      "Pro has no price on the paywall")

        // "You are here". The most useful thing a price list can tell somebody.
        XCTAssertTrue(app.staticTexts["CURRENT"].exists,
                      "the paywall does not say which plan the student is on")
    }

    /// The other way in.
    ///
    /// There were two graders until recently — this button opened a `Form`
    /// sheet that could not upload, could not photograph a rubric and never
    /// asked how the course marks, while Tools opened the real thing. They are
    /// one flow now, and this is what proves the assignment screen actually
    /// pushes it rather than silently doing nothing: `navigationDestination`
    /// has failed quietly in this app before.
    func testMarkingFromAnAssignmentOpensTheSameGrader() throws {
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
