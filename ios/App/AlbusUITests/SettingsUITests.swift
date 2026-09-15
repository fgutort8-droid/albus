import XCTest

/// The fourth tab, and the plan meters on it.
///
/// Ask Albus held this slot until it moved inside a task and became Pro-only.
/// These tests exist to catch the two ways that change could be half-done: a
/// tab bar still pointing at a screen that no longer exists, and a plan card
/// that reads a zero allowance as "unlimited" — the inverted sentinel that
/// would quietly hand every free student the paid features.
@MainActor
final class SettingsUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = false }

    func testSettingsIsInTheTabBar() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 15),
                      "Settings is not in the tab bar")
        XCTAssertFalse(app.buttons["Albus"].exists,
                       "there is no chat tab; the app does not have a chatbot")
    }

    /// The plan card is the only place a student can see what they are on.
    func testSettingsShowsThePlanAndItsMeters() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)
        app.buttons["Settings"].tap()

        XCTAssertTrue(app.buttons["See the plans"].waitForExistence(timeout: 15),
                      "no plan section on Settings")

        let early = XCTAttachment(screenshot: app.screenshot())
        early.name = "settings-free"
        early.lifetime = .keepAlways
        add(early)

        // A fresh account is Free, and Free includes no marking and no chat.
        // "Not included" and "0 left" are different sentences on purpose; this
        // asserts the card is not quietly rendering a zero as unlimited.
        let notIncluded = app.staticTexts.matching(
            NSPredicate(format: "label == 'Not included'"))
        XCTAssertGreaterThanOrEqual(notIncluded.count, 1,
                                    "a Free account should see at least one 'Not included' row")
        XCTAssertFalse(app.staticTexts["Unlimited"].exists,
                       "a Free account is reading a zero allowance as unlimited")

    }

    /// Notifications were reachable only from one small button on Home.
    func testNotificationsAreReachableFromSettings() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)
        app.buttons["Settings"].tap()

        let entry = app.staticTexts["When Albus speaks"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "no notifications entry on Settings")
        entry.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 10),
                      "the notifications link does not open notification settings")
    }
}
