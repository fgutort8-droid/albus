import XCTest

/// Every place the app links the terms, the privacy policy and the support
/// page, tapped, with the page Safari then shows checked by text found only on
/// that page. A page's own links name the others ("Privacy policy" is on the
/// terms page), so a heading shared with a link would prove nothing.
///
/// Launches signed in with the plan forced, or signed out, so no account is
/// created and nothing is bought. Skipped in CI because it opens the live
/// pages; `LegalLinkDestinationsUITests` checks the same links offline there.
@MainActor
final class LegalLinksUITests: XCTestCase {

    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    override func setUp() {
        continueAfterFailure = false
    }

    /// Text that appears on one page only.
    private enum Page: String {
        case terms = "1. Who can use Albus"
        case privacy = "1. Who is responsible"
        case support = "Common questions"
    }

    private func launch(signedIn: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
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

    /// Taps `link`, checks Safari opens on `page`, then comes back to the app.
    private func open(_ link: XCUIElement, expecting page: Page, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(link.waitForExistence(timeout: 30), "no link to \(page)",
                      file: file, line: line)
        for _ in 0..<4 where !link.isHittable { app.swipeUp() }
        link.tap()
        // A tap that lands while the page is still settling is taken as
        // stopping the scroll, not as a tap; one more covers that.
        if !safari.wait(for: .runningForeground, timeout: 5) { link.tap() }
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30),
                      "\(page): Safari never opened", file: file, line: line)
        XCTAssertTrue(safari.webViews.staticTexts[page.rawValue].waitForExistence(timeout: 30),
                      "\(page): Safari opened on a different page", file: file, line: line)
        add(XCTAttachment(screenshot: safari.screenshot()))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    func testSettingsLinksAllThreePages() {
        let app = launch(signedIn: true)
        open(app.buttons["Help and support"], expecting: .support, in: app)
        open(app.buttons["Privacy policy"], expecting: .privacy, in: app)
        open(app.buttons["Terms of service"], expecting: .terms, in: app)
    }

    func testPaywallLinksTermsAndPrivacy() {
        let app = launch(signedIn: true)
        let entry = app.buttons.matching(
            NSPredicate(format: "label == 'See the plans' OR label == 'Change plan'")).firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 30))
        entry.tap()
        let skip = app.otherElements["Skip the introduction"]
        if skip.waitForExistence(timeout: 10) { skip.tap() }
        // The purchase bar rises last; until it has, the footer may not exist.
        let purchase = app.buttons.matching(NSPredicate(format:
            "label == 'Your plan' OR label BEGINSWITH 'Subscribe to' "
            + "OR label BEGINSWITH 'Switch to' OR label BEGINSWITH 'Start ' "
            + "OR label == 'Free is included' OR label == 'Manage subscription' "
            + "OR label == 'Loading prices'")).firstMatch
        XCTAssertTrue(purchase.waitForExistence(timeout: 60), "the paywall never finished presenting")
        open(app.buttons["Terms"], expecting: .terms, in: app)
        open(app.buttons["Privacy"], expecting: .privacy, in: app)
    }

    /// The line under the sign-in buttons. Nothing here signs in.
    func testSignInLinksTermsAndPrivacy() {
        let app = launch(signedIn: false)
        XCTAssertTrue(app.buttons["Terms of service"].waitForExistence(timeout: 30), "the sign-in screen comes first")
        open(app.buttons["Terms of service"], expecting: .terms, in: app)
        open(app.buttons["Privacy policy"], expecting: .privacy, in: app)
    }
}
