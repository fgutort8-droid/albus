import Testing
import Foundation
@testable import AlbusCore

/// Fixed clock so every case is reproducible. Wed 20 May 2026, 09:00 local.
private let cal = Scheduler.defaultCalendar
private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    cal.date(from: DateComponents(year: 2026, month: 5, day: day, hour: hour, minute: minute))!
}
private let now = at(20, 9)
private let planner = NotificationPlanner()

private func assignment(_ title: String = "Bio IA",
                        dueDay: Int = 23, dueHour: Int = 17,
                        steps: Int = 3, minutes: Int = 120,
                        complete: Bool = false,
                        nextStep: String? = "Outline the method",
                        unplaceable: Bool = false,
                        id: UUID = UUID()) -> NotificationAssignment {
    NotificationAssignment(id: id, title: title, deadline: at(dueDay, dueHour),
                           isComplete: complete, remainingSteps: steps,
                           remainingMinutes: minutes, nextStepTitle: nextStep,
                           hasUnplaceable: unplaceable)
}

private func block(_ day: Int, _ hour: Int, minutes: Int = 45,
                   step: String = "Outline the method",
                   assignment: UUID = UUID()) -> NotificationBlock {
    NotificationBlock(assignmentID: assignment, assignmentTitle: "Bio IA",
                      stepTitle: step, start: at(day, hour), minutes: minutes)
}

private func context(assignments: [NotificationAssignment] = [],
                     blocks: [NotificationBlock] = [],
                     settings: NotificationSettings = .default,
                     workload: WorkloadState = .busy,
                     unplaceableCount: Int = 0,
                     signature: String = "",
                     previousSignature: String = "",
                     pausedUntil: Date? = nil,
                     weeklyMinutes: Int = 0,
                     lastOpened: Date = at(20, 8),
                     at moment: Date = now) -> NotificationContext {
    NotificationContext(assignments: assignments, blocks: blocks, workload: workload,
                        settings: settings, weeklyFocusedMinutes: weeklyMinutes,
                        lastOpened: lastOpened, unplaceableCount: unplaceableCount,
                        unplaceableSignature: signature,
                        previousUnplaceableSignature: previousSignature,
                        pausedUntil: pausedUntil, now: moment)
}

@Suite("Notification planning")
struct NotificationPlanningTests {

    @Test("an empty store says nothing")
    func emptySaysNothing() {
        #expect(planner.plan(context()).isEmpty)
    }

    @Test("disabled means silent, whatever else is true")
    func disabledIsSilent() {
        var settings = NotificationSettings.default
        settings.enabled = false
        let result = planner.plan(context(assignments: [assignment()],
                                          blocks: [block(20, 17)],
                                          settings: settings))
        #expect(result.isEmpty)
    }

    @Test("an assignment with work produces a brief")
    func producesABrief() {
        let result = planner.plan(context(assignments: [assignment()],
                                          blocks: [block(21, 17)]))
        #expect(result.contains { $0.kind == .morningBrief })
    }

    @Test("a completed assignment is not chased")
    func completedIsNotChased() {
        let result = planner.plan(context(assignments: [assignment(complete: true)]))
        #expect(result.isEmpty)
    }

    @Test("every line renders with no placeholder left behind")
    func noUnresolvedPlaceholders() {
        let result = planner.plan(context(
            assignments: [assignment(), assignment("History essay", dueDay: 21, steps: 5)],
            blocks: [block(20, 17), block(21, 16)],
            weeklyMinutes: 200
        ))
        #expect(!result.isEmpty)
        for notification in result {
            #expect(!notification.title.contains("{"), "title: \(notification.title)")
            #expect(!notification.body.contains("{"), "body: \(notification.body)")
        }
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {

    @Test("nothing is delivered inside quiet hours")
    func nothingInQuietHours() {
        // A 01:00 deadline drags its T-3h to 22:00 the night before.
        let result = planner.plan(context(
            assignments: [assignment(dueDay: 22, dueHour: 1)],
            blocks: [block(21, 17)]
        ))
        for notification in result {
            let hour = cal.component(.hour, from: notification.fireDate)
            #expect(hour >= 7 && hour < 22,
                    "\(notification.kind) fired at \(hour):00")
        }
    }

    @Test("quiet hours move forward, never backward")
    func movesForward() {
        let settled = planner.movedOutOfQuietHours(at(20, 23), .default)
        #expect(settled == at(21, 7))
    }

    @Test("an early-morning time moves to the same day's end of quiet")
    func earlyMorningSameDay() {
        let settled = planner.movedOutOfQuietHours(at(20, 2), .default)
        #expect(settled == at(20, 7))
    }

    @Test("a time outside quiet hours is untouched")
    func outsideIsUntouched() {
        #expect(planner.movedOutOfQuietHours(at(20, 15), .default) == at(20, 15))
    }

    @Test("a quiet window that does not wrap midnight still works")
    func nonWrappingWindow() {
        var settings = NotificationSettings.default
        settings.quietStartHour = 13
        settings.quietEndHour = 15
        #expect(planner.isQuiet(at(20, 14), settings))
        #expect(!planner.isQuiet(at(20, 12), settings))
        #expect(planner.movedOutOfQuietHours(at(20, 14), settings) == at(20, 15))
    }

    @Test("a warning that would settle past its own deadline is dropped, not moved")
    func droppedRatherThanMoved() {
        // Deadline 02:00. T-3h is 23:00, inside quiet hours; moving it forward
        // would deliver it at 07:00 — five hours after the hand-in.
        let due = assignment(dueDay: 22, dueHour: 2)
        let result = planner.plan(context(assignments: [due]))
        #expect(!result.contains { $0.kind == .deadline03 })
    }
}

@Suite("Volume")
struct VolumeTests {

    @Test("the daily cap holds for everything that is not urgent")
    func capHolds() {
        var settings = NotificationSettings.default
        settings.warnAt72h = true
        let many = (0..<8).map { i in
            assignment("Essay \(i)", dueDay: 23, dueHour: 12 + (i % 6), steps: 2)
        }
        let result = planner.plan(context(assignments: many,
                                          blocks: [block(20, 17), block(21, 17)],
                                          settings: settings))

        let byDay = Dictionary(grouping: result.filter { $0.kind.tier != 1 }) {
            cal.startOfDay(for: $0.fireDate)
        }
        for (day, items) in byDay {
            #expect(items.count <= settings.maxPerDay,
                    "\(items.count) non-urgent on \(day)")
        }
    }

    @Test("due-today is never suppressed by the volume cap")
    func urgentIsExempt() {
        var settings = NotificationSettings.default
        settings.maxPerDay = 1
        let result = planner.plan(context(
            assignments: [assignment("Bio IA", dueDay: 21, dueHour: 17)],
            blocks: [block(21, 9), block(21, 16)],
            settings: settings
        ))
        #expect(result.contains { $0.kind == .handInToday })
    }

    @Test("due today replaces the brief rather than arriving beside it")
    func handInSupersedesBrief() {
        let result = planner.plan(context(
            assignments: [assignment(dueDay: 21, dueHour: 17)],
            blocks: [block(21, 16)]
        ))
        let day = cal.startOfDay(for: at(21, 9))
        let thatDay = result.filter { cal.startOfDay(for: $0.fireDate) == day }
        #expect(thatDay.contains { $0.kind == .handInToday })
        #expect(!thatDay.contains { $0.kind == .morningBrief })
    }

    @Test("the 64-slot budget is never exceeded")
    func budgetHolds() {
        var settings = NotificationSettings.default
        settings.warnAt72h = true
        let many = (0..<40).map { i in
            assignment("Essay \(i)", dueDay: 21 + (i % 8), dueHour: 10 + (i % 8), steps: 3)
        }
        let result = planner.plan(context(assignments: many, settings: settings))
        #expect(result.count <= NotificationPlanner.budget)
    }

    @Test("when the budget bites, the nearest deadlines are what survive")
    func budgetKeepsNearest() {
        var settings = NotificationSettings.default
        settings.warnAt72h = true
        let many = (0..<40).map { i in
            assignment("Essay \(i)", dueDay: 21 + (i % 10), dueHour: 12, steps: 3)
        }
        let result = planner.plan(context(assignments: many, settings: settings))
        guard result.count == NotificationPlanner.budget else { return }
        let latest = result.map(\.fireDate).max()!
        // Nothing kept should be further out than something dropped would be.
        #expect(latest <= at(31, 23))
    }
}

@Suite("Plan stopped fitting")
struct UnfitTests {

    @Test("fires when the unplaceable set changes")
    func firesOnTransition() {
        let result = planner.plan(context(
            assignments: [assignment(unplaceable: true)],
            unplaceableCount: 2, signature: "abc", previousSignature: ""
        ))
        #expect(result.contains { $0.kind == .planStoppedFitting })
    }

    @Test("does not fire again while the same work stays unplaceable")
    func doesNotRepeat() {
        let result = planner.plan(context(
            assignments: [assignment(unplaceable: true)],
            unplaceableCount: 2, signature: "abc", previousSignature: "abc"
        ))
        #expect(!result.contains { $0.kind == .planStoppedFitting })
    }

    @Test("says nothing when everything fits")
    func silentWhenFitting() {
        let result = planner.plan(context(assignments: [assignment()],
                                          signature: "", previousSignature: "abc"))
        #expect(!result.contains { $0.kind == .planStoppedFitting })
    }
}

@Suite("Back-off")
struct BackOffTests {

    @Test("while paused, only real consequences get through")
    func pausedKeepsUrgent() {
        let result = planner.plan(context(
            assignments: [assignment("Late one", dueDay: 19, dueHour: 12),
                          assignment("Future one", dueDay: 25)],
            blocks: [block(20, 17), block(21, 17)],
            pausedUntil: at(30, 9)
        ))
        for notification in result {
            #expect(notification.kind.tier == 1 || notification.kind == .backOff,
                    "\(notification.kind) survived the pause")
        }
    }

    @Test("the pause announces itself exactly once")
    func announcesOnce() {
        let result = planner.plan(context(
            assignments: [assignment()],
            pausedUntil: at(30, 9)
        ))
        #expect(result.filter { $0.kind == .backOff }.count == 1)
    }

    @Test("dormancy is not scheduled while paused")
    func noDormancyWhilePaused() {
        let result = planner.plan(context(
            assignments: [assignment()],
            pausedUntil: at(30, 9),
            lastOpened: at(10, 9)
        ))
        #expect(!result.contains { $0.kind == .dormantSoft || $0.kind == .dormantFinal })
    }
}

@Suite("Stability — the property users feel")
struct NotificationStabilityTests {

    @Test("planning twice produces exactly the same thing")
    func idempotent() {
        let input = context(assignments: [assignment(), assignment("History", dueDay: 22)],
                            blocks: [block(20, 17), block(21, 16)])
        let first = planner.plan(input)
        let second = planner.plan(input)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.map(\.fireDate) == second.map(\.fireDate))
        #expect(first.map(\.body) == second.map(\.body))
    }

    @Test("the order assignments arrive in does not change the output")
    func orderIndependent() {
        let a = assignment("Bio IA", dueDay: 23)
        let b = assignment("History", dueDay: 22)
        let c = assignment("Maths", dueDay: 24)

        let forward = planner.plan(context(assignments: [a, b, c]))
        let backward = planner.plan(context(assignments: [c, b, a]))
        #expect(forward.map(\.id).sorted() == backward.map(\.id).sorted())
    }

    @Test("nothing is ever scheduled in the past")
    func neverInThePast() {
        let result = planner.plan(context(
            assignments: [assignment("Yesterday", dueDay: 19, dueHour: 12),
                          assignment("Soon", dueDay: 20, dueHour: 23)],
            blocks: [block(20, 8)]
        ))
        for notification in result {
            #expect(notification.fireDate > now, "\(notification.kind) is in the past")
        }
    }

    @Test("identifiers are unique within one plan")
    func identifiersUnique() {
        let result = planner.plan(context(
            assignments: (0..<6).map { assignment("Essay \($0)", dueDay: 21 + $0) },
            blocks: [block(20, 17), block(21, 17), block(22, 17)]
        ))
        #expect(Set(result.map(\.id)).count == result.count)
    }

    @Test("a spring-forward day still produces exactly one brief")
    func dstProducesOneBrief() {
        // 29 March 2026, 01:00 -> 02:00 in most of Europe.
        let dstNow = cal.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 9))!
        let due = NotificationAssignment(
            id: UUID(), title: "Bio IA",
            deadline: cal.date(from: DateComponents(year: 2026, month: 4, day: 3, hour: 17))!,
            isComplete: false, remainingSteps: 3, remainingMinutes: 120,
            nextStepTitle: "Outline"
        )
        let result = planner.plan(context(assignments: [due], at: dstNow))
        let briefs = result.filter { $0.kind == .morningBrief }
        let days = Set(briefs.map { cal.startOfDay(for: $0.fireDate) })
        #expect(briefs.count == days.count, "more than one brief on some day")
    }
}

/// Four bugs that every test above passed straight through.
///
/// They were found by printing a realistic week and reading it — which is worth
/// recording, because each one would have reached a student's lock screen and
/// none of them was a crash, a throw, or anything a type could have caught.
@Suite("Regressions — found by reading real output")
struct NotificationRegressionTests {

    /// Said "Bio IA in 80 hours" on a three-hour warning, because every
    /// time-relative fact was measured from when the plan was *built* rather
    /// than from when the notification would *arrive*.
    @Test("hours are counted from the moment it fires, not the moment it was planned")
    func factsAreRelativeToFireTime() {
        let due = assignment("Bio IA", dueDay: 23, dueHour: 17)
        let result = planner.plan(context(assignments: [due]))
        guard let warning = result.first(where: { $0.kind == .deadline03 }) else {
            Issue.record("no T-3h warning"); return
        }
        let text = warning.title + " " + warning.body

        // Asserting on *any* number of hours the line quotes, rather than on
        // one expected phrasing. The first version of this test demanded the
        // literal "3 hours" and broke the moment the picker chose a line that
        // spells the number out — testing the corpus rather than the bug.
        for quoted in numbers(before: "hour", in: text) {
            #expect(quoted <= 3, "counted \(quoted) hours from planning time: \(text)")
        }
    }

    /// Every integer immediately preceding a given word.
    private func numbers(before word: String, in text: String) -> [Int] {
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
        return zip(parts, parts.dropFirst()).compactMap { current, next in
            next.hasPrefix(word) ? Int(current) : nil
        }
    }

    @Test("days are counted from the moment it fires too")
    func daysAreRelativeToFireTime() {
        // Due Sat 23. The T-24h warning arrives Fri 22 and must say one day,
        // not the three that were left when the plan was made.
        let result = planner.plan(context(assignments: [assignment(dueDay: 23, dueHour: 17)]))
        guard let warning = result.first(where: { $0.kind == .deadline24 }) else {
            Issue.record("no T-24h warning"); return
        }
        #expect(!(warning.title + warning.body).contains("3 days"))
    }

    /// Produced "0 minutes across 0 steps" on any day with nothing scheduled.
    @Test("a day with nothing scheduled gets no brief")
    func noBriefWithoutBlocks() {
        let result = planner.plan(context(assignments: [assignment(dueDay: 28)], blocks: []))
        #expect(!result.contains { $0.kind == .morningBrief })
    }

    @Test("a day with work does get one")
    func briefWhenThereIsWork() {
        let result = planner.plan(context(assignments: [assignment(dueDay: 28)],
                                          blocks: [block(21, 17)]))
        #expect(result.contains { $0.kind == .morningBrief })
    }

    /// A 09:00 deadline put its T-3h at 06:00; quiet hours moved it to 07:00;
    /// the hand-in warning was already at 07:30. Same assignment, twice, half
    /// an hour apart.
    @Test("one assignment never speaks twice within three hours")
    func noCrowding() {
        let result = planner.plan(context(
            assignments: [assignment("History essay", dueDay: 21, dueHour: 9)],
            blocks: [block(20, 17)]
        ))
        let history = result.filter { $0.threadID != nil }
            .sorted { $0.fireDate < $1.fireDate }

        for (earlier, later) in zip(history, history.dropFirst())
        where earlier.threadID == later.threadID {
            let gap = later.fireDate.timeIntervalSince(earlier.fireDate)
            #expect(gap >= 3 * 3600,
                    "\(earlier.kind) and \(later.kind) are \(Int(gap / 60)) minutes apart")
        }
    }

    /// "1 days left", "1 steps remaining".
    @Test("one of something is singular")
    func pluralisation() {
        let result = planner.plan(context(
            assignments: [assignment("Bio IA", dueDay: 21, dueHour: 17,
                                     steps: 1, minutes: 1, nextStep: nil)],
            blocks: [block(20, 17)]
        ))
        for notification in result {
            let text = notification.title + " " + notification.body
            #expect(!text.contains("1 days"), "said: \(text)")
            #expect(!text.contains("1 steps"), "said: \(text)")
            #expect(!text.contains("1 minutes"), "said: \(text)")
            #expect(!text.contains("1 hours"), "said: \(text)")
        }
    }
}

/// Two more, found the same way as the four above — by reading what the app had
/// actually queued with the system, this time out of the simulator's own
/// notification store rather than out of a print.
@Suite("Regressions — found in the real pending queue")
struct NotificationQueueRegressionTests {

    /// Shipped the line "Sci is the past out and today owes it 162 minutes".
    /// A brief three days ahead named the nearest open assignment, which by the
    /// day that brief arrived was already overdue, so `{days}` rendered as a
    /// phrase that only reads correctly in the future tense.
    @Test("a brief never describes a deadline that has passed by the time it arrives")
    func briefDoesNotNameAPastDeadline() {
        let result = planner.plan(context(
            assignments: [assignment("Sci", dueDay: 21, dueHour: 17, steps: 4),
                          assignment("Art", dueDay: 27, dueHour: 17, steps: 4)],
            blocks: [block(20, 17), block(21, 17), block(22, 17), block(23, 17)]
        ))
        for notification in result where notification.kind == .morningBrief {
            let text = notification.title + " " + notification.body
            #expect(!text.contains("the past"), "said: \(text)")
        }
    }

    /// Shipped "English essay, 1220 minutes of work, one evening. Tight but
    /// real." Twenty hours is not one evening, and nobody reads 1220 minutes.
    @Test("long durations are said in hours, not in hundreds of minutes")
    func longDurationsReadAsHours() {
        let result = planner.plan(context(
            assignments: [assignment("English essay", dueDay: 21, dueHour: 17,
                                     steps: 8, minutes: 1_220)],
            blocks: [block(20, 17)]
        ))
        #expect(!result.isEmpty)
        for notification in result {
            let text = notification.title + " " + notification.body
            #expect(!text.contains("1220 minutes"), "said: \(text)")
        }
    }

    @Test("short durations are still said in minutes")
    func shortDurationsStayMinutes() {
        let result = planner.plan(context(
            assignments: [assignment("Bio IA", dueDay: 22, steps: 1, minutes: 45)],
            blocks: [block(20, 17, minutes: 45)]
        ))
        let nudges = result.filter { $0.kind == .windowNudge }
        #expect(nudges.contains { ($0.title + $0.body).contains("45 minutes") })
    }

    /// A quiet-app reminder named the nearest open assignment even when it was
    /// overdue, or due later that day, by the time the reminder fired, so
    /// `{days}` came out as "today" in lines written for a day or more ahead.
    @Test("a quiet-app reminder never names a deadline less than a day away")
    func dormancyNamesOnlyDeadlinesAhead() {
        var reminders = 0
        // Eleven different days, so the seeded pick lands on lines that name
        // the assignment as well as lines that do not.
        for opened in 10...20 {
            let result = planner.plan(context(
                assignments: [assignment("Sci", dueDay: opened + 2, dueHour: 17),
                              assignment("Art", dueDay: opened + 3, dueHour: 17)],
                lastOpened: at(opened, 8),
                at: at(opened, 9)
            ))
            for notification in result
            where notification.kind == .dormantSoft || notification.kind == .dormantFinal {
                reminders += 1
                let text = notification.title + " " + notification.body
                #expect(!text.contains("today"), "said: \(text)")
                #expect(!text.contains("Sci") && !text.contains("Art"), "said: \(text)")
            }
        }
        #expect(reminders > 0)
    }

    @Test("a quiet-app reminder still names a deadline days away")
    func dormancyStillNamesDeadlinesAhead() {
        var named = false
        for opened in 10...20 {
            let result = planner.plan(context(
                assignments: [assignment("Art", dueDay: opened + 10, dueHour: 17)],
                lastOpened: at(opened, 8),
                at: at(opened, 9)
            ))
            for notification in result
            where notification.kind == .dormantSoft || notification.kind == .dormantFinal {
                let text = notification.title + " " + notification.body
                #expect(!text.contains("today"), "said: \(text)")
                named = named || text.contains("Art")
            }
        }
        #expect(named)
    }
}
