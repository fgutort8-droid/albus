import Foundation
import Testing
@testable import AlbusCore

@Suite("Local plan")
struct LocalPlanTests {

    @Test("Sessions add up to exactly the time the student budgeted")
    func conservesTime() {
        for total in [5, 45, 59, 120, 121, 480, 600, 2_400, 12_000] {
            for capacity in [0, 30, 45, 60, 150, 240, 960] {
                let plan = LocalPlan.sessions(title: "Essay", totalMinutes: total,
                                              dailyCapacityMinutes: capacity)
                #expect(plan.map(\.minutes).reduce(0, +) == total,
                        "\(total) min at \(capacity)/day lost or invented time")
            }
        }
    }

    // The regression that matters: a session longer than the student's day is
    // skipped by the scheduler on every day, so it never appears anywhere.
    @Test("No session is ever longer than one sitting")
    func everySessionFitsADay() {
        for total in [5, 45, 121, 480, 601, 2_400, 12_000] {
            for capacity in [0, 30, 45, 60, 150, 240, 960] {
                let ceiling = LocalPlan.sittingCeiling(dailyCapacityMinutes: capacity)
                let plan = LocalPlan.sessions(title: "Essay", totalMinutes: total,
                                              dailyCapacityMinutes: capacity)
                #expect(plan.allSatisfy { $0.minutes <= ceiling && $0.minutes > 0 },
                        "\(total) min at \(capacity)/day produced an unplaceable session")
            }
        }
    }

    @Test("A sitting is between half an hour and two hours, whatever the day")
    func ceilingBounds() {
        #expect(LocalPlan.sittingCeiling(dailyCapacityMinutes: 0) == 30)
        #expect(LocalPlan.sittingCeiling(dailyCapacityMinutes: 90) == 90)
        #expect(LocalPlan.sittingCeiling(dailyCapacityMinutes: 960) == 120)
    }

    @Test("A small task stays one session, named as the task")
    func smallTaskIsNotPadded() {
        let plan = LocalPlan.sessions(title: "Maths homework", totalMinutes: 45,
                                      dailyCapacityMinutes: 150)
        #expect(plan == [.init(title: "Maths homework", minutes: 45)])
    }

    @Test("Larger work is numbered so the student can see how far along they are")
    func largerWorkIsNumbered() {
        let plan = LocalPlan.sessions(title: "History essay", totalMinutes: 240,
                                      dailyCapacityMinutes: 150)
        #expect(plan.count > 1)
        #expect(plan.first?.title == "History essay (1 of \(plan.count))")
        #expect(plan.last?.title == "History essay (\(plan.count) of \(plan.count))")
    }

    @Test("Every session the phone makes can actually be scheduled")
    func sessionsAreScheduled() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let availability = Availability(windowStartHour: 0, windowEndHour: 24,
                                        dailyCapacityMinutes: 60)
        let assignment = UUID()
        let items = LocalPlan.sessions(title: "Lab report", totalMinutes: 300,
                                       dailyCapacityMinutes: 60)
            .enumerated()
            .map { i, session in
                ScheduleItem(id: UUID(), assignmentID: assignment, ordinal: i,
                             minutes: session.minutes,
                             deadline: now.addingTimeInterval(14 * 86_400))
            }
        let result = Scheduler().schedule(items: items, availability: availability, now: now)
        #expect(result.unplaceable.isEmpty)
        #expect(result.sessions.count == items.count)
    }
}
