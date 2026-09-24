import XCTest

/// The screen that takes the money, rendered without a backend, an account or
/// a purchase.
///
/// **Why this file exists.** The paywall was reachable only by walking real
/// onboarding, which creates a genuine account on the production project and
/// spends a real Claude call to build the first plan. CI skips those tests for
/// that reason, so the one screen whose entire job is selling a subscription
/// was covered by nothing that ever ran.
///
/// These launch straight into Settings with the plan forced, so they cost
/// nothing, need no network, and run on every change. `-albus.debug.forcePlan`
/// is compiled out of Release and grants no entitlement: every limit is
/// enforced again in the database, in the same transaction as the write.
@MainActor
final class PaywallUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = false
    }

    /// Settings, with the student on `plan`, and no way to spend anything.
    private func launch(on plan: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-albus.debug.assumeSignedIn",
            "-albus.profile.onboarded", "YES",
            "-albus.debug.skipNotificationPrompt",
            "-albus.debug.noPurchases",
            "-albus.debug.openSettings",
            "-albus.debug.forcePlan", plan,
        ]
        app.launch()
        return app
    }

    /// Settings names the button for what it does, so both titles open it.
    ///
    /// Returns once the paywall has settled, not once it has been asked for.
    /// The sheet presents, the intro plays and the cards rise in sequence, so
    /// a test that starts querying immediately races the layout and fails on a
    /// wait rather than on what it came to check.
    private func openPaywall(_ app: XCUIApplication,
                             file: StaticString = #filePath, line: UInt = #line) {
        let entry = app.buttons.matching(
            NSPredicate(format: "label == 'See the plans' OR label == 'Change plan'")
        ).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30),
                      "Settings offers no way to reach the plans", file: file, line: line)
        entry.tap()

        // The intro animation runs first; a tap skips it.
        let skip = app.otherElements["Skip the introduction"]
        if skip.waitForExistence(timeout: 10) { skip.tap() }

        // The purchase bar is the last thing to rise, so its arrival means
        // the three cards are laid out behind it.
        XCTAssertTrue(purchaseButton(app).waitForExistence(timeout: 30),
                      "the paywall never finished presenting", file: file, line: line)
    }

    /// One plan's card. Matched on its own label rather than a descendant's:
    /// `PlanCard` sets an explicit accessibility label, which is the contract.
    private func card(_ plan: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", plan + ",")).firstMatch
    }

    /// The one button at the bottom, whatever it currently says.
    private func purchaseButton(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format:
            "label == 'Your plan' OR label BEGINSWITH 'Subscribe to' "
            + "OR label BEGINSWITH 'Switch to' OR label BEGINSWITH 'Start ' "
            + "OR label == 'Free is included' OR label == 'Manage subscription'"
        )).firstMatch
    }

    /// Lifted from the old live-backend test, which is the only place this had
    /// ever been checked.
    ///
    /// **Visible, not merely present.** The three cards sat below the fold
    /// behind the purchase bar in the first version of this screen, and
    /// `waitForExistence` was perfectly happy — an element that exists
    /// somewhere nobody can see it still exists. A student could not compare
    /// three prices on the screen whose only job is comparing three prices.
    func testThreePlansAreVisibleAndPriced() {
        let app = launch(on: "free")
        openPaywall(app)

        let window = app.windows.element(boundBy: 0).frame
        for plan in ["Free", "Plus", "Pro"] {
            let card = card(plan, in: app)
            XCTAssertTrue(card.waitForExistence(timeout: 20),
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

        // A card with no price is not a plan.
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '9.99'")).element.waitForExistence(timeout: 5),
                      "Plus has no price on the paywall")
        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '17.99'")).element.exists,
                      "Pro has no price on the paywall")
    }

    /// "You are here", and the rule underneath it.
    ///
    /// A subscriber must never be sold what they already have. The card says
    /// which plan is theirs, and selecting it turns the button into a
    /// statement rather than an offer — the failure this guards against is a
    /// Pro subscriber being invited to buy Pro again.
    func testASubscriberIsToldWhichPlanIsTheirsAndCannotRebuyIt() {
        let app = launch(on: "pro")
        openPaywall(app)

        let pro = card("Pro", in: app)
        XCTAssertTrue(pro.waitForExistence(timeout: 20), "Pro is missing from the paywall")
        XCTAssertTrue(pro.label.contains("your current plan"),
                      "the paywall does not say which plan the student is on "
                      + "(Pro reads '\(pro.label)')")
        XCTAssertTrue(app.staticTexts["CURRENT"].exists,
                      "nothing on the paywall is marked as the current plan")

        // The screen opens on Plus, so a Pro subscriber is first offered a
        // downgrade — which is an offer, and must stay live.
        let downgrade = app.buttons["Switch to Plus"]
        XCTAssertTrue(downgrade.waitForExistence(timeout: 20),
                      "a Pro subscriber is not offered the switch down to Plus")
        XCTAssertTrue(downgrade.isEnabled, "the switch to Plus is dead")

        pro.tap()

        let ownPlan = app.buttons["Your plan"]
        XCTAssertTrue(ownPlan.waitForExistence(timeout: 20),
                      "selecting the plan the student already pays for still "
                      + "offers to sell it to them")
        XCTAssertFalse(ownPlan.isEnabled,
                       "a Pro subscriber can tap buy on Pro")

        attach(app.screenshot(), named: "paywall-current-plan")
    }

    /// Free is not a purchase, and saying so is the difference between an
    /// honest price list and a dark pattern.
    ///
    /// A free student who taps the Free card is already on it, so the button
    /// states that rather than offering it — and the caption sends them back
    /// to the plans rather than leaving them on a dead button with no next
    /// step.
    func testFreeIsNotSoldToAStudentWhoAlreadyHasIt() {
        let app = launch(on: "free")
        openPaywall(app)

        let free = card("Free", in: app)
        XCTAssertTrue(free.waitForExistence(timeout: 20), "Free is missing from the paywall")
        free.tap()

        let ownPlan = app.buttons["Your plan"]
        XCTAssertTrue(ownPlan.waitForExistence(timeout: 20),
                      "Free is being offered for sale to a student already on it")
        XCTAssertFalse(ownPlan.isEnabled, "Free has a live buy button")

        XCTAssertTrue(app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] 'Pick a plan above'")).element.exists,
                      "a free student is left on a dead button with nothing to do next")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
