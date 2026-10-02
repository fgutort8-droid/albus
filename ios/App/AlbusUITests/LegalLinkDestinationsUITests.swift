import XCTest

/// Where every link to the terms, privacy policy and support page goes,
/// checked without the network, so it runs in CI.
///
/// `-albus.debug.recordLinks` makes the app record the address a link would
/// open instead of opening it (see `DebugLinkRecording`). `LegalLinksUITests`
/// opens the live pages instead, and runs on a developer's machine.
@MainActor
final class LegalLinkDestinationsUITests: XCTestCase {

    private let terms = "https://albus-app.netlify.app/terms/"
    private let privacy = "https://albus-app.netlify.app/privacy/"
    private let support = "https://albus-app.netlify.app/support/"

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-albus.debug.recordLinks",
            "-albus.debug.skipNotificationPrompt",
            "-albus.debug.noPurchases",
            "-albus.debug.forcePlan", "free",
        ]
        app.launchArguments += signedIn
            ? ["-albus.debug.assumeSignedIn", "-albus.profile.onboarded", "YES", "-albus.debug.openSettings"]
            : ["-albus.debug.assumeSignedOut"]
        app.launch()
        return app
    }

    /// Taps `link` and checks the app was asked to open exactly `url`.
    private func expect(_ link: XCUIElement, opens url: String, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(link.waitForExistence(timeout: 30), "no link to \(url)", file: file, line: line)
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        link.tap()
        let recorded = app.staticTexts["debug.lastOpenedURL"]
        let opened = NSPredicate(format: "label == %@", url)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: opened, evaluatedWith: recorded)], timeout: 10),
                       .completed, "expected \(url), got \(recorded.label)", file: file, line: line)
    }

    func testSettingsLinks() {
        let app = launch(signedIn: true)
        expect(app.buttons["Help and support"], opens: support, in: app)
        expect(app.buttons["Privacy policy"], opens: privacy, in: app)
        expect(app.buttons["Terms of service"], opens: terms, in: app)
    }

    /// Opens the paywall and returns once it has settled: the purchase bar
    /// rises last, and until it has, the footer may not exist.
    private func openPaywall(_ app: XCUIApplication) {
        let entry = app.buttons.matching(
            NSPredicate(format: "label == 'See the plans' OR label == 'Change plan'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        let purchase = app.buttons.matching(NSPredicate(format:
            "label == 'Your plan' OR label BEGINSWITH 'Subscribe to' "
            + "OR label BEGINSWITH 'Switch to' OR label BEGINSWITH 'Start ' "
            + "OR label == 'Free is included' OR label == 'Manage subscription' "
            + "OR label == 'Loading prices'")).firstMatch
        // A tap while the screen is still settling can be lost; one more covers that.
        for _ in 0..<2 where !purchase.exists {
            entry.tap()
            let skip = app.otherElements["Skip the introduction"]
            if skip.waitForExistence(timeout: 10) { skip.tap() }
            _ = purchase.waitForExistence(timeout: 30)
        }
        XCTAssertTrue(purchase.exists, "the paywall never finished presenting")
    }

    func testPaywallLinks() {
        let app = launch(signedIn: true)
        // The recording sits behind the paywall, so each check closes it.
        for (label, url) in [("Terms", terms), ("Privacy", privacy)] {
            openPaywall(app)
            let link = app.buttons[label]
            XCTAssertTrue(link.waitForExistence(timeout: 10), "the paywall has no \(label) link")
            link.tap()
            app.buttons["Close"].tap()
            let recorded = app.staticTexts["debug.lastOpenedURL"]
            let opened = NSPredicate(format: "label == %@", url)
            XCTAssertEqual(XCTWaiter().wait(for: [expectation(for: opened, evaluatedWith: recorded)], timeout: 10),
                           .completed, "the paywall's \(label) link: expected \(url), got \(recorded.label)")
        }
    }

    func testSignInLinks() {
        let app = launch(signedIn: false)
        XCTAssertTrue(app.buttons["signIn.email"].waitForExistence(timeout: 30), "the sign-in screen comes first")
        expect(app.links["Terms of service"], opens: terms, in: app)
        expect(app.links["Privacy policy"], opens: privacy, in: app)
    }
}
