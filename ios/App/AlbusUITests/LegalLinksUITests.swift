import XCTest

/// Every place the app links the terms, the privacy policy and the support
/// page, tapped, with the page Safari then shows checked by its heading.
///
/// Launches signed in with the plan forced, so no account is created and
/// nothing is bought. Skipped in CI because it opens the live pages: a runner
/// without the network would fail it for reasons that say nothing about the app.
@MainActor
final class LegalLinksUITests: XCTestCase {

    private let safari = XCUIApplication(bundleIdentifier: "com.apple.mobilesafari")

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-albus.debug.assumeSignedIn",
            "-albus.profile.onboarded", onboarded ? "YES" : "NO",
            "-albus.debug.skipNotificationPrompt",
            "-albus.debug.noPurchases",
            "-albus.debug.forcePlan", "free",
        ]
        if onboarded { app.launchArguments.append("-albus.debug.openSettings") }
        app.launch()
        return app
    }

    /// Taps `link`, checks Safari opens on the page whose heading is
    /// `heading`, then comes back to the app.
    private func open(_ link: XCUIElement, expecting heading: String, in app: XCUIApplication,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(link.waitForExistence(timeout: 30), "no link to \(heading)",
                      file: file, line: line)
        if !link.isHittable { app.swipeUp() }
        link.tap()
        // A tap that lands while the page is still settling is taken as
        // stopping the scroll, not as a tap; one more covers that.
        if !safari.wait(for: .runningForeground, timeout: 5) { link.tap() }
        XCTAssertTrue(safari.wait(for: .runningForeground, timeout: 30),
                      "\(heading): Safari never opened", file: file, line: line)
        XCTAssertTrue(safari.webViews.staticTexts[heading].waitForExistence(timeout: 30),
                      "\(heading): Safari opened on a different page", file: file, line: line)
        add(XCTAttachment(screenshot: safari.screenshot()))
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), file: file, line: line)
    }

    func testSettingsLinksAllThreePages() {
        let app = launch(onboarded: true)
        let terms = app.buttons["Terms of service"]
        XCTAssertTrue(terms.waitForExistence(timeout: 30))
        for _ in 0..<4 where !terms.isHittable { app.swipeUp() }
        open(app.buttons["Help and support"], expecting: "Help and support", in: app)
        open(app.buttons["Privacy policy"], expecting: "Privacy policy", in: app)
        open(app.buttons["Terms of service"], expecting: "Terms of service", in: app)
    }

    func testPaywallLinksTermsAndPrivacy() {
        let app = launch(onboarded: true)
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
        open(app.buttons["Terms"], expecting: "Terms of service", in: app)
        open(app.buttons["Privacy"], expecting: "Privacy policy", in: app)
    }

    /// The line beside "Build my plan". Nothing here taps that button, so no
    /// account is created.
    func testSignUpLinksTermsAndPrivacy() {
        let app = launch(onboarded: false)
        let next = app.buttons["Next"]
        XCTAssertTrue(next.waitForExistence(timeout: 30))
        next.tap()
        XCTAssertTrue(app.buttons["Build my plan"].waitForExistence(timeout: 10))
        open(app.links["Terms of service"], expecting: "Terms of service", in: app)
        open(app.links["Privacy policy"], expecting: "Privacy policy", in: app)
    }
}
