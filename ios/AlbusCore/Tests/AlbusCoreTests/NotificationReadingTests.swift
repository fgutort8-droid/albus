import Testing
import Foundation
@testable import AlbusCore

/// Fixed clock, as in `NotificationPlannerTests`: May 2026, local time.
private let cal = Scheduler.defaultCalendar
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute))!
}
private let planner = NotificationPlanner()

private func assignment(_ title: String, dueDay: Int, dueHour: Int = 17,
                        unplaceable: Bool = false) -> NotificationAssignment {
    NotificationAssignment(id: UUID(), title: title, deadline: at(dueDay, dueHour),
                           isComplete: false, remainingSteps: 3,
                           remainingMinutes: 120, nextStepTitle: "Outline the method",
                           hasUnplaceable: unplaceable)
}

private func plan(_ assignments: [NotificationAssignment], opened: Int, plain: Bool,
                  blocks: [NotificationBlock] = [],
                  unplaceableCount: Int = 0, signature: String = "") -> [PlannedNotification] {
    var settings = NotificationSettings.default
    settings.seriousMode = plain
    return planner.plan(NotificationContext(
        assignments: assignments, blocks: blocks, workload: .busy,
        settings: settings, weeklyFocusedMinutes: 0,
        lastOpened: at(opened, 8), unplaceableCount: unplaceableCount,
        unplaceableSignature: signature, previousUnplaceableSignature: "",
        pausedUntil: nil, now: at(opened, 9)))
}

private func text(_ notification: PlannedNotification) -> String {
    notification.title + " " + notification.body
}

/// "1 assignments", "1 steps": a one followed by a plural.
private func countsOneAsSeveral(_ text: String) -> Bool {
    text.range(of: #"(^|[^0-9])1 (assignments|steps|days|hours|minutes)\b"#,
               options: .regularExpression) != nil
}

/// Found by printing the reminders a realistic fortnight produces and reading
/// them, during the pre-submission audit of November 2026. The suite was green
/// throughout: nothing asserted on how a line reads with one of something, or
/// on the characters a lock screen would show.
@Suite("Regressions — reminders read as written")
struct NotificationReadingTests {

    /// "It's been a few days — 1 assignments are still open."
    @Test("one open assignment is never counted as several", arguments: [false, true])
    func oneAssignmentIsNotAPlural(plain: Bool) {
        var seen = 0
        for opened in 8...20 {
            // Overdue by the time either quiet-app reminder arrives, due on
            // the day of the second, and due well after both.
            for due in [opened + 2, opened + 7, opened + 12] {
                for notification in plan([assignment("History essay", dueDay: due)],
                                         opened: opened, plain: plain) {
                    seen += 1
                    #expect(!countsOneAsSeveral(text(notification)), "said: \(text(notification))")
                }
            }
        }
        #expect(seen > 0)
    }

    /// Without the count, and with nothing due a day or more ahead to name,
    /// the plain quiet-app reminders had no line left and would have gone
    /// silent. Each must still arrive.
    @Test("a plain quiet-app reminder still arrives with one assignment, already due")
    func plainQuietRemindersStillArrive() {
        for opened in 8...20 {
            let result = plan([assignment("History essay", dueDay: opened + 2)],
                              opened: opened, plain: true)
            #expect(result.filter { $0.kind == .dormantSoft }.count == 1)
            #expect(result.filter { $0.kind == .dormantFinal }.count == 1)
        }
    }

    /// "Your plan no longer fits — 1 steps can't be scheduled before their deadline."
    @Test("one step that no longer fits is never counted as several", arguments: [false, true])
    func oneUnplacedStepIsNotAPlural(plain: Bool) {
        for opened in 8...20 {
            let result = plan([assignment("History essay", dueDay: opened + 4, unplaceable: true)],
                              opened: opened, plain: plain,
                              unplaceableCount: 1, signature: "one-step")
            let warnings = result.filter { $0.kind == .planStoppedFitting }
            // The one reminder no other app can send must not be the price.
            #expect(warnings.count == 1)
            for notification in warnings {
                #expect(!countsOneAsSeveral(text(notification)), "said: \(text(notification))")
            }
        }
    }

    /// The count is withheld for one, not dropped: several are still counted.
    @Test("several open assignments are still counted")
    func severalAreStillCounted() {
        var counted = false
        for opened in 8...20 {
            for plainRegister in [false, true] {
                let result = plan([assignment("History essay", dueDay: opened + 2),
                                   assignment("Sci lab report", dueDay: opened + 3)],
                                  opened: opened, plain: plainRegister)
                counted = counted || result.contains { text($0).contains("2 assignments") }
            }
        }
        #expect(counted)
        #expect(NotificationPlanner.countable(1) == nil)
        #expect(NotificationPlanner.countable(0) == "0")
        #expect(NotificationPlanner.countable(2) == "2")
    }

    /// "This is the one — History essay is due tomorrow. **Outline the method**
    /// is where you start." A notification shows its text exactly as given.
    @Test("no reminder carries the bold markers its line was written with")
    func noBoldMarkersReachTheLockScreen() {
        // The lines themselves still carry them, or this proves nothing.
        let marked = Corpus.all.filter { ($0.title + $0.body).contains("**") }
        #expect(marked.count >= 10)

        var facts = Facts()
        for fact in Fact.allCases { facts[fact] = "Outline the method" }
        for template in Corpus.all {
            guard let rendered = NotificationCopy.render(template, facts: facts) else {
                Issue.record("\(template.id) did not render"); continue
            }
            #expect(!(rendered.title + rendered.body).contains("*"), "\(template.id): \(rendered)")
        }

        // And through the planner, on a week with a step to point at.
        var planned = 0
        for opened in 8...20 {
            let essay = assignment("History essay", dueDay: opened + 2)
            let block = NotificationBlock(assignmentID: essay.id, assignmentTitle: essay.title,
                                          stepTitle: "Outline the method",
                                          start: at(opened + 1, 17), minutes: 45)
            for plainRegister in [false, true] {
                for notification in plan([essay], opened: opened, plain: plainRegister, blocks: [block]) {
                    planned += 1
                    #expect(!text(notification).contains("*"), "said: \(text(notification))")
                }
            }
        }
        #expect(planned > 0)
    }
}
