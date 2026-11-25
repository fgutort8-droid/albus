import XCTest

@MainActor
final class EntitlementRefreshUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testFailedPlanRefreshIsVisibleRetryableAndDismissible() {
        app.launchArguments += [
            "-albus.debug.assumeSignedIn",
            "-albus.profile.onboarded", "YES",
            // Answered, so the one-time AI question does not cover the app.
            "-albus.ai.allowed", "NO",
            "-albus.debug.openSettings",
            "-albus.debug.failEntitlementRefresh",
        ]
        app.launch()

        // SwiftUI may expose the containing HStack as a group or another
        // element depending on the OS point release. The identifier is the
        // contract; the synthesized accessibility element type is not.
        let notice = app.descendants(matching: .any)["entitlementRefreshFailure"]
        XCTAssertTrue(notice.waitForExistence(timeout: 15),
                      "a failed plan refresh stayed invisible")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "stale plan figures are visible"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["retryEntitlementRefresh"].tap()
        XCTAssertTrue(notice.waitForExistence(timeout: 5),
                      "retry did not run the forced failure path")

        app.buttons["Dismiss plan warning"].tap()
        XCTAssertFalse(notice.waitForExistence(timeout: 2),
                       "the quiet warning could not be dismissed")
    }
}
