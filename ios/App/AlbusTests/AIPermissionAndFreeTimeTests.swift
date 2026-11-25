import Foundation
import Testing
import AlbusCore
@testable import Albus

/// Asking students when they are free, and whether Albus may use the AI.
///
/// Before this, every student was planned 4pm to 10pm every day, so one still
/// in lessons at 4pm got sessions during school; and work was sent to
/// Anthropic with no question asked in the app (App Review 5.1.2(i)).
@MainActor
@Suite("Free time and AI permission")
struct AIPermissionAndFreeTimeTests {

    private func fresh() -> (Preferences, UserDefaults) {
        let defaults = UserDefaults(suiteName: "albus.tests.prefs.\(UUID().uuidString)")!
        return (Preferences(defaults: defaults), defaults)
    }

    @Test("a student who joined before has their weekends planned in their old hours")
    func weekendsFollowSchoolDaysUntilSet() {
        let (prefs, _) = fresh()
        prefs.windowStartHour = 17
        prefs.windowEndHour = 21
        #expect(prefs.weekendStartHour == nil)
        #expect(prefs.availability.window(onWeekday: 7) == (17, 21))
    }

    @Test("weekend hours are kept, and used on Saturday and Sunday only")
    func weekendHoursPersist() {
        let (prefs, defaults) = fresh()
        prefs.windowStartHour = 17
        prefs.windowEndHour = 21
        prefs.weekendStartHour = 10
        prefs.weekendEndHour = 18
        let again = Preferences(defaults: defaults)
        #expect(again.availability.window(onWeekday: 1) == (10, 18))
        #expect(again.availability.window(onWeekday: 7) == (10, 18))
        #expect(again.availability.window(onWeekday: 4) == (17, 21))
    }

    @Test("nothing may go to the AI until the student says yes")
    func aiNeedsAYes() {
        let (prefs, defaults) = fresh()
        #expect(prefs.aiAllowed == nil)
        #expect(!prefs.mayUseAI)
        prefs.aiAllowed = false
        #expect(!Preferences(defaults: defaults).mayUseAI)
        prefs.aiAllowed = true
        #expect(Preferences(defaults: defaults).mayUseAI)
    }

    @Test("an answer given at launch, as text, is read as an answer")
    func launchArgumentAnswer() {
        let (_, defaults) = fresh()
        defaults.set("NO", forKey: "albus.ai.allowed")
        #expect(Preferences(defaults: defaults).aiAllowed == false)
        defaults.set("YES", forKey: "albus.ai.allowed")
        #expect(Preferences(defaults: defaults).aiAllowed == true)
    }

    @Test("deleting the account forgets both answers")
    func resetForgets() {
        let (prefs, defaults) = fresh()
        prefs.weekendStartHour = 9
        prefs.aiAllowed = true
        prefs.resetAfterAccountDeletion()
        let again = Preferences(defaults: defaults)
        #expect(again.weekendStartHour == nil)
        #expect(again.aiAllowed == nil)
    }

    @Test("until always stays after from")
    func untilFollowsFrom() {
        #expect(HourRangePicker.until(afterMoving: 18, until: 22) == 22)
        #expect(HourRangePicker.until(afterMoving: 21, until: 20) == 22)
        #expect(HourRangePicker.until(afterMoving: 23, until: 23) == 24)
    }

    /// The AI is used from SwiftUI views a test cannot tap, so this reads the
    /// source, as `PlanDoorWiringTests` does: every place that can send work
    /// to the AI first asks whether it may.
    @Test("every way to the AI asks the student's permission")
    func everyDoorAsks() throws {
        func source(_ path: String) throws -> String {
            let url = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Albus/\(path)")
            return try String(contentsOf: url, encoding: .utf8)
        }
        let home = try source("Screens/HomeScreen.swift")
        let onboarding = try source("Screens/OnboardingFlow.swift")
        let grader = try source("Screens/GraderScreen.swift")
        let root = try source("Shell/RootView.swift")
        #expect(home.contains("useAI: preferences.mayUseAI"))
        #expect(onboarding.contains("useAI: preferences.mayUseAI"))
        #expect(onboarding.contains("if preferences.aiAllowed == nil { step = .aiPermission }"))
        #expect(grader.contains("if preferences.mayUseAI { Task { await submit() } } else { askingAI = true }"))
        #expect(grader.components(separatedBy: "await submit()").count - 1 == 2,
                "submit is reached only from the guarded button and the Allow answer")
        #expect(root.contains("Binding(get: { preferences.aiAllowed == nil }"))
        #expect(grader.contains("mayUseAI: { [preferences] in preferences.mayUseAI }"),
                "the marking reads the answer at each send, retries included")
    }
}
