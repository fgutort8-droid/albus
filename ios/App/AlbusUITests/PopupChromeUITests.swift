import XCTest

/// The popups that stopped being system popups.
///
/// Both were the default grouped look — a `Form` in a `NavigationStack`, and a
/// system action sheet — and both are now the app's own chrome. A sheet that
/// fails to present, or presents empty, is the most visible possible bug and
/// the least likely to be caught by anything else in this repo: nothing else
/// here opens them.
///
/// Screenshots are attached so a failure can be looked at rather than inferred.
@MainActor
final class PopupChromeUITests: XCTestCase {

    private let app = XCUIApplication()

    override func setUp() { continueAfterFailure = false }

    /// Leaving the app is the one place Albus vouches for someone else's
    /// software, and *why* is the useful half — a system dialog rendered that
    /// as grey subtitle text under a shouted title.
    func testLeavingForAToolIsAnAlbusSheet() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Tools"].tap()

        // Any tool card. The catalogue is two hundred entries of other people's
        // software and this test is about the chrome, not about which one.
        let tool = app.scrollViews.buttons.element(boundBy: 4)
        XCTAssertTrue(tool.waitForExistence(timeout: 15), "no tool cards on Tools")
        tool.tap()

        XCTAssertTrue(app.staticTexts["LEAVING ALBUS"].waitForExistence(timeout: 10),
                      "the leaving sheet did not present")
        XCTAssertTrue(app.buttons["Open in Safari"].exists,
                      "the leaving sheet presented without its action")

        attach(app.screenshot(), named: "leaving-albus")
    }

    /// Editing a step was a `Form` with a system Cancel/Save toolbar —
    /// indistinguishable from any other app's settings screen.
    func testEditingAStepUsesTheSheetScaffold() throws {
        OnboardingPath.launch(app)
        OnboardingPath.reachApp(app)

        app.buttons["Home"].tap()

        let card = app.descendants(matching: .any)
            .matching(identifier: "assignmentCard").element(boundBy: 0)
        guard card.waitForExistence(timeout: 30) else {
            throw XCTSkip("no assignment on Home to open")
        }
        card.tap()

        // Addressed by its own label. There are two ellipsis menus on this
        // screen and the other one deletes the assignment, so a predicate that
        // matched "ellipsis" would be one tap away from a destructive action
        // in a test that is supposed to be about a text field.
        let menu = app.buttons["Edit plan"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15),
                      "no plan menu on the assignment screen")
        menu.tap()

        let add = app.buttons["Add a step"]
        XCTAssertTrue(add.waitForExistence(timeout: 5), "no 'Add a step' in the plan menu")
        add.tap()

        try assertStepSheet()
    }

    private func assertStepSheet() throws {
        XCTAssertTrue(app.staticTexts["ADDING A STEP"].waitForExistence(timeout: 10),
                      "the step editor did not present in Albus chrome")
        XCTAssertTrue(app.staticTexts["What are you doing?"].exists,
                      "the step editor presented without its headline")
        // The scaffold's pinned action, not a system toolbar button.
        XCTAssertTrue(app.buttons["Save"].exists, "no primary action on the step editor")

        attach(app.screenshot(), named: "step-editor")
    }

    private func attach(_ screenshot: XCUIScreenshot, named name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
