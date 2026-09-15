import XCTest

/// Drives the real app against the real backend: add an assignment, wait for
/// Albus to plan it, confirm the placed sessions appear, then walk the tabs the
/// plan feeds.
///
/// Deliberately not mocked. The seam between app and backend is the one place
/// nothing else exercises — every bug found while building this connection
/// (a missing config value, a reserved error code, an env prefix) lived
/// exactly there and was invisible to unit tests and to a passing build.
///
/// Kept out of the default test plan because it costs a real Anthropic call.
/// Run explicitly:
///   xcodebuild test -scheme Albus -only-testing:AlbusUITests
/// `@MainActor` is required, not stylistic: XCUITest's APIs are main-actor
/// isolated under Swift 6, and Xcode 16.4 rejects calling them from a
/// nonisolated test method. Xcode 26 accepted it locally, so this only failed
/// on CI — which is exactly why CI compiles the target even when skipping it.
@MainActor
final class CoreLoopUITests: XCTestCase {

    /// Unique per test.
    ///
    /// A shared constant meant the second test found the row the first had left
    /// behind and failed on "multiple matching elements" — the tests were
    /// coupled through the live database, which is exactly what a suite hitting
    /// a real backend must not be.
    ///
    /// Initialised here rather than in `setUp`, which is nonisolated under
    /// Xcode 16.4 and so cannot assign to a MainActor-isolated property. XCTest
    /// builds a fresh instance per test method, so this is still unique per test.
    private let assignmentTitle = "Biology chapter \(UUID().uuidString.prefix(6))"

    private let app = XCUIApplication()

    override func setUp() {
        continueAfterFailure = false
    }

    func testAddAssignmentProducesAPlacedPlan() throws {
        OnboardingPath.launch(app)

        OnboardingPath.reachApp(app)
        XCTAssertFalse(app.staticTexts.containing(
            NSPredicate(format: "label BEGINSWITH 'Not signed in'")).element.exists,
            "sign-in failed")

        addAssignment(app, titled: assignmentTitle)

        // Assert on the assignment, not on a placed session.
        //
        // A session-level assertion passed at noon and failed at 23:58, because
        // late in the evening the scheduler correctly places everything in
        // tomorrow's window rather than at midnight — a test failing for a
        // reason the app is right about. Home lists every assignment regardless
        // of when its sessions land, so this checks the same thing without
        // depending on the clock.
        app.buttons["Home"].tap()
        XCTAssertTrue(app.staticTexts[assignmentTitle].waitForExistence(timeout: 90),
                      "no plan appeared — breakdown, persistence or scheduling failed")
    }

    /// The plan has to be reachable from Home and openable into its steps —
    /// the screens a student actually works from.
    func testPlanIsVisibleOnHomeAndInDetail() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        addAssignment(app, titled: assignmentTitle)

        app.buttons["Home"].tap()

        // Addressed by identifier, not by label. Home shows the assignment title
        // in two places — the up-next row and the assignment card — and they do
        // different things: one starts a focus session, the other opens the
        // plan. Matching on the title picked whichever came first in the tree,
        // which was the up-next row, so this test opened Focus Mode and then
        // correctly reported that no plan was visible.
        let card = app.descendants(matching: .any)
            .matching(identifier: "assignmentCard").element(boundBy: 0)
        XCTAssertTrue(card.waitForExistence(timeout: 90),
                      "the assignment is missing from Home")
        XCTAssertTrue(app.staticTexts[assignmentTitle].waitForExistence(timeout: 5),
                      "the assignment's title never rendered")

        card.tap()

        // Assert on the plan's *content*, not on its heading.
        //
        // This used to look for the "ALBUS'S PLAN" section header, which broke
        // the moment that header gained a menu button: SwiftUI stops combining
        // an accessibility element that contains an interactive child, so the
        // exact label disappeared even though the screen was correct. A test
        // that fails when a button is added next to a title is testing the
        // wrong thing.
        //
        // Every generated plan has at least one step and every step carries a
        // duration, so this proves steps rendered rather than just a header.
        let durations = app.staticTexts.containing(
            NSPredicate(format: "label MATCHES %@", #"^\d+h( \d+m)?$|^\d+m$"#))
        XCTAssertTrue(durations.element(boundBy: 0).waitForExistence(timeout: 15),
                      "task detail did not show the generated plan")

        // And the plan has to be startable, which is the whole point of the
        // screen. This is also the regression guard for "Start session" having
        // silently been a second Mark done button.
        XCTAssertTrue(app.buttons.containing(
            NSPredicate(format: "label BEGINSWITH 'Start'")).element.exists,
            "no way to start a session from the plan")
    }

    /// Tools is static, so this is cheap — but it is the one tab that opens
    /// external links, and a crash here would only ever be found by tapping.
    func testToolsLibraryRenders() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()

        // Asserting on one tool's name made this fail the moment the catalogue
        // was reorganised, which is a test breaking for a reason nobody cares
        // about. What matters is that the library rendered at all and that
        // search narrows it.
        XCTAssertTrue(app.textFields["Search tools"].waitForExistence(timeout: 10),
                      "the tool library did not render")
        OnboardingPath.type("grammar", into: app.textFields["Search tools"])
        XCTAssertTrue(app.staticTexts["Grammarly"].waitForExistence(timeout: 5),
                      "search did not narrow the library")
    }

    // MARK: - Helpers

    private func addAssignment(_ app: XCUIApplication, titled title: String) {
        app.buttons["Add assignment"].firstMatch.tap()

        OnboardingPath.type(title, into: app.textFields["What is it?"])

        app.buttons["Plan it"].tap()
    }


    /// Deleting an assignment, through the screens a student actually uses.
    ///
    /// Deliberately end-to-end: the risk is not the delete itself but what the
    /// app does immediately afterwards — a detail screen laying out work that no
    /// longer exists, or a card that stays on Home.
    ///
    /// Deletes whatever is already on Home rather than adding first. Free caps
    /// active assignments at five, so a suite that always adds one eventually
    /// meets the paywall instead of the add sheet — which is the situation this
    /// feature exists to get a student out of. The number is read from
    /// `public.plans` by everything that enforces it; this comment is the only
    /// place it is written down, and only to explain the shape of the test.
    func testDeleteRemovesTheAssignmentFromHome() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)
        app.buttons["Home"].tap()

        let cards = app.descendants(matching: .any).matching(identifier: "assignmentCard")
        if !cards.element(boundBy: 0).waitForExistence(timeout: 20) {
            addAssignment(app, titled: assignmentTitle)
            app.buttons["Home"].tap()
            XCTAssertTrue(cards.element(boundBy: 0).waitForExistence(timeout: 90),
                          "no assignment to delete")
        }

        let before = cards.count
        let card = cards.element(boundBy: 0)

        // Long-press, because Home is a stack of cards rather than a List. A
        // press that lands while Home is still animating in opens the
        // assignment instead, so wait for the card to settle, and come back and
        // press again once if it opened anyway. A missing menu still fails.
        let delete = app.buttons["Delete assignment"]
        for _ in 0..<2 {
            OnboardingPath.waitUntilStill(card)
            card.press(forDuration: 1.1)
            if delete.waitForExistence(timeout: 3) { break }
            let back = app.buttons["Back to home"]
            if back.exists { back.tap() }
        }
        XCTAssertTrue(delete.waitForExistence(timeout: 2), "no way to delete from Home")
        delete.tap()

        let confirm = app.buttons["Delete"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "deleted without asking first")
        confirm.tap()

        // One fewer card, and the app is still standing.
        let fewer = NSPredicate(format: "count == %d", before - 1)
        expectation(for: fewer, evaluatedWith: cards)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(app.buttons["Home"].exists, "the app did not survive the delete")
    }
}
