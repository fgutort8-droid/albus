import Foundation

/// A unit of work waiting to be placed in time.
///
/// Deliberately a value type with no database or UI knowledge: the scheduler
/// must be reasonable about in isolation, and anything it can reach into is
/// something a test has to stand up.
public struct ScheduleItem: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let assignmentID: UUID
    /// Position within its assignment. Steps are meant to be done in order.
    public let ordinal: Int
    public let duration: TimeInterval
    public let deadline: Date
    /// The student's own urgency, higher first.
    ///
    /// Only ever breaks a tie between two pieces of work already competing for
    /// the same window — see `Scheduler.priorityOrder`. It cannot move anything
    /// past a deadline, because deadline remains the leading sort key.
    public let priority: Int

    public init(id: UUID, assignmentID: UUID, ordinal: Int, minutes: Int,
                deadline: Date, priority: Int = 1) {
        self.id = id
        self.assignmentID = assignmentID
        self.ordinal = ordinal
        self.duration = TimeInterval(max(1, minutes) * 60)
        self.deadline = deadline
        self.priority = priority
    }
}

/// Something the student did not choose: a class, a shift, a fixed commitment.
/// The scheduler routes around these and never through them.
public struct FixedCommitment: Sendable, Equatable {
    public let start: Date
    public let end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = min(max(start, end), start.addingTimeInterval(24 * 3600))
    }
}

public enum SessionState: String, Sendable, Codable, CaseIterable {
    case scheduled, active, completed, missed, skipped

    /// Completed and in-progress work is history. The scheduler reads it to
    /// know what time is gone, and never rewrites it. Public because the
    /// persistence layer must honour the same rule when reconciling.
    public var isImmutable: Bool {
        self == .completed || self == .active
    }
}

public struct PlannedSession: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let itemID: UUID
    public let assignmentID: UUID
    public let start: Date
    public let end: Date
    public var state: SessionState

    public init(id: UUID = UUID(), itemID: UUID, assignmentID: UUID,
                start: Date, end: Date, state: SessionState = .scheduled) {
        self.id = id
        self.itemID = itemID
        self.assignmentID = assignmentID
        self.start = start
        self.end = end
        self.state = state
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

/// When the plan does not fit, that is a result rather than an error — and the
/// signal the mascot's mood is derived from, so it has to be first-class.
public enum WorkloadState: String, Sendable, Equatable {
    case calm, busy, cooked
}

public struct ScheduleResult: Sendable, Equatable {
    public let sessions: [PlannedSession]
    /// Work that could not be placed before its deadline. Never silently dropped.
    public let unplaceable: [ScheduleItem]
    public let workload: WorkloadState
    /// How many previously-scheduled sessions this run moved. Low is the goal;
    /// a high number is the failure mode users experience as untrustworthiness.
    public let movedCount: Int
}

/// When the student is willing to work, and how much they will take on.
public struct Availability: Sendable, Equatable {
    /// The school-day window, Monday to Friday.
    public let windowStartHour: Int
    public let windowEndHour: Int
    /// The Saturday and Sunday window. The school-day hours when not given,
    /// which is how every student was planned before weekends had their own.
    public let weekendWindowStartHour: Int
    public let weekendWindowEndHour: Int
    public let dailyCapacityMinutes: Int
    /// Weekday numbers (1 = Sunday, per Calendar) that are entirely off.
    public let excludedWeekdays: Set<Int>

    public init(windowStartHour: Int = 16, windowEndHour: Int = 22,
                weekendWindowStartHour: Int? = nil, weekendWindowEndHour: Int? = nil,
                dailyCapacityMinutes: Int = 150, excludedWeekdays: Set<Int> = []) {
        (self.windowStartHour, self.windowEndHour) = Self.clamped(windowStartHour, windowEndHour)
        (self.weekendWindowStartHour, self.weekendWindowEndHour) = Self.clamped(
            weekendWindowStartHour ?? windowStartHour, weekendWindowEndHour ?? windowEndHour)
        self.dailyCapacityMinutes = max(0, min(24 * 60, dailyCapacityMinutes))
        self.excludedWeekdays = excludedWeekdays
    }

    /// Hours inside a day, and an end at least an hour after the start.
    private static func clamped(_ start: Int, _ end: Int) -> (Int, Int) {
        let start = max(0, min(23, start))
        return (start, max(start + 1, min(24, end)))
    }

    /// The window on a weekday (1 = Sunday, 7 = Saturday, per Calendar).
    public func window(onWeekday weekday: Int) -> (startHour: Int, endHour: Int) {
        weekday == 1 || weekday == 7
            ? (weekendWindowStartHour, weekendWindowEndHour)
            : (windowStartHour, windowEndHour)
    }

    public static let `default` = Availability()
}
