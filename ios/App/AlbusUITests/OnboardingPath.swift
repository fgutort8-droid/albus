import XCTest

/// Getting a fresh install as far as the app.
///
/// One copy, because there were two and they went stale together: both tapped
/// "Next" exactly once and then expected the deadline field, which stopped
/// being true the day onboarding gained a subject-picker step between them.
/// Every UI test in this target failed on the same line for a reason that had
/// nothing to do with what any of them was testing.
///
/// So this walks the flow rather than counting screens: whatever advance button
/// is on screen gets tapped until the one step that needs typing appears. A
/// sixth step added tomorrow costs nothing here.
@MainActor
enum OnboardingPath {

    /// Launches the app for a test that goes through onboarding.
    ///
    /// "Show me" asks for notification permission and waits for the answer.
    /// XCUITest keeps that system prompt from presenting, so on a freshly
    /// erased device the request never returns and onboarding never finishes.
    /// A student sees the prompt and answers it; a test skips it.
    static func launch(_ app: XCUIApplication) {
        app.launchArguments += ["-albus.debug.skipNotificationPrompt"]
        app.launch()
    }

    /// Titles that mean "carry on" at some step of onboarding. The subject
    /// picker offers "Skip for now" until something is selected, and offering a
    /// student a step they have nothing to say to is the point of it.
    private static let advanceTitles = ["Next", "Skip for now", "Continue"]

    /// Taps a field and types into it once it has focus.
    ///
    /// `tap()` then `typeText()` races focus: the tap registers before focus
    /// lands, and typing fails with "neither element nor any descendant has
    /// keyboard focus". The software keyboard is not a usable signal: on an
    /// erased simulator a hardware keyboard counts as connected, so it never
    /// appears. This waits on the field's own focus instead, and taps once more
    /// if the first tap landed while the screen was still settling.
    static func type(_ text: String, into field: XCUIElement,
                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(field.waitForExistence(timeout: 10), "field never appeared",
                      file: file, line: line)
        for _ in 0..<2 {
            field.tap()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline {
                if (field.value(forKey: "hasKeyboardFocus") as? Bool) == true {
                    field.typeText(text)
                    return
                }
                usleep(100_000)
            }
        }
        XCTFail("field never took keyboard focus", file: file, line: line)
    }

    /// Waits until an element stops moving.
    ///
    /// A long-press that starts while a view is still animating in reads as a
    /// tap: the view moves under a stationary finger, which cancels the press
    /// and leaves only the touch-up.
    static func waitUntilStill(_ element: XCUIElement, timeout: TimeInterval = 5) {
        var last = element.frame
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            usleep(250_000)
            let now = element.frame
            if now == last { return }
            last = now
        }
    }

    static func reachApp(_ app: XCUIApplication, file: StaticString = #filePath,
                         line: UInt = #line) {
        let home = app.buttons["Home"]        // present in the app, absent in onboarding
        let onboarding = app.staticTexts["A few things first."]

        // Whichever appears first decides the path. An install that already has
        // a session never sees onboarding at all.
        let start = Date()
        while Date().timeIntervalSince(start) < 25 {
            if home.exists { return }
            if onboarding.exists { break }
            usleep(200_000)
        }
        guard onboarding.exists else {
            XCTAssertTrue(home.waitForExistence(timeout: 20),
                          "neither onboarding nor the app appeared", file: file, line: line)
            return
        }

        let deadlineField = app.textFields["e.g. History term paper"]

        // Bounded so a flow that stops advancing fails as a test rather than
        // hanging until the whole scheme times out.
        for _ in 0..<8 {
            if deadlineField.exists { break }
            guard let advance = advanceTitles.lazy
                .map({ app.buttons[$0] })
                .first(where: { $0.exists && $0.isHittable })
            else {
                usleep(300_000)
                continue
            }
            advance.tap()
            usleep(400_000)
        }

        XCTAssertTrue(deadlineField.waitForExistence(timeout: 15),
                      "onboarding never reached the deadline step", file: file, line: line)
        type("Onboarding first assignment", into: deadlineField, file: file, line: line)

        app.buttons["Build my plan"].tap()

        // Account creation plus a real Claude call.
        let done = app.buttons["Show me"]
        XCTAssertTrue(done.waitForExistence(timeout: 120),
                      "onboarding never finished — account creation or the first plan failed",
                      file: file, line: line)
        done.tap()

        // Generous, and measured rather than guessed: tapping "Show me" is
        // followed by the first store write, the first sync and the tab bar's
        // own appearance, and on a cold simulator that ran past twenty seconds
        // and failed a test about something else entirely.
        XCTAssertTrue(home.waitForExistence(timeout: 60),
                      "onboarding completed but the app never appeared", file: file, line: line)
    }
}
