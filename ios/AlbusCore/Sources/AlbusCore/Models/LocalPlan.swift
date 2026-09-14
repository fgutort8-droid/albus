import Foundation

/// A plan made on the device, with no model call.
///
/// Used whenever an AI plan is not available — the student's weekly AI plans
/// are used up, their plan does not include them, or there is no connection.
/// It divides the budgeted time into sittings using the same arithmetic the
/// server hands the model (`sessionCeiling` in `breakdown_schema.ts`, the step
/// count in `prompt.ts`), so a phone-made plan and an AI plan are sized alike.
public enum LocalPlan {

    public struct Session: Sendable, Equatable {
        public let title: String
        public let minutes: Int
    }

    /// The longest single sitting.
    ///
    /// A session longer than the student's day is never placed: the scheduler
    /// skips any day without room for the whole block, so it silently vanishes
    /// from the calendar. Capped at two hours because three unbroken hours on
    /// one task is not a realistic unit of study.
    public static func sittingCeiling(dailyCapacityMinutes: Int) -> Int {
        max(30, min(120, dailyCapacityMinutes))
    }

    /// Sessions adding up to exactly the budget, none longer than a sitting.
    public static func sessions(title: String, totalMinutes: Int,
                                dailyCapacityMinutes: Int) -> [Session] {
        let total = max(5, totalMinutes)
        let ceiling = sittingCeiling(dailyCapacityMinutes: dailyCapacityMinutes)
        let typical = min(75, ceiling)

        // As many sittings as the budget suggests at a typical length, and never
        // fewer than it takes to keep every one inside the ceiling. A small task
        // stays one session rather than being padded into a plan.
        let count = max(1,
                        Int((Double(total) / Double(typical)).rounded()),
                        Int((Double(total) / Double(ceiling)).rounded(.up)))

        let base = total / count
        let extra = total % count
        return (0..<count).map { i in
            Session(
                title: String((count == 1 ? title : "\(title) (\(i + 1) of \(count))").prefix(200)),
                minutes: base + (i < extra ? 1 : 0))
        }
    }
}
