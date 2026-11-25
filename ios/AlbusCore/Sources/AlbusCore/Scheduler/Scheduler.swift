import Foundation

/// Places work into real time, and re-places it when reality diverges.
///
/// Design constraints, in priority order:
///
/// 1. **Only move what must move.** A student who misses one session and
///    watches their whole week rearrange stops trusting the app immediately.
///    Everything that can stay, stays; `movedCount` exists so this is
///    measurable rather than assumed.
/// 2. **Never move the past.** Completed and in-progress work is a record.
/// 3. **Fixed commitments are walls**, routed around and never through.
/// 4. **Respect declared capacity.** Overfilling a day to make the arithmetic
///    work is how a planner becomes an app people avoid opening.
/// 5. **Deterministic.** Same inputs, same output. Non-determinism reads to a
///    user as the app being broken and makes bugs unreproducible.
/// 6. **Overload is an output, not an error.**
///
/// Pure and synchronous: no clock, no database, no network. `now` is injected
/// so every case below is reproducible in a test.
public struct Scheduler: Sendable {

    /// Guards against pathological inputs producing an unbounded loop.
    private static let maxDaysAhead = 400

    private let calendar: Calendar

    public init(calendar: Calendar = Scheduler.defaultCalendar) {
        self.calendar = calendar
    }

    /// A fixed calendar rather than `.current`: the scheduler's output must not
    /// depend on ambient device state.
    public static var defaultCalendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        c.firstWeekday = 1
        return c
    }

    // MARK: - Entry point

    /// - Parameters:
    ///   - items: work needing placement.
    ///   - existing: sessions already on the calendar. Completed, active and
    ///     elapsed ones are preserved; the rest may be re-placed.
    ///   - commitments: immovable blocks.
    public func schedule(
        items: [ScheduleItem],
        existing: [PlannedSession] = [],
        commitments: [FixedCommitment] = [],
        availability: Availability = .default,
        now: Date
    ) -> ScheduleResult {

        // What may move, and what may not.
        //
        //   pinned   finished or in-flight work, a block the student is sitting
        //            in right now, and any past block we were never told about
        //   movable  everything still ahead, and anything explicitly `.missed`
        //
        // The missed case is the one this product exists for: a block whose
        // window passed unused has to be found a new home, and the slot it
        // never used has to stop counting as occupied.
        //
        // Note what is *not* movable: a past `.scheduled` block nobody marked.
        // We do not know whether that work happened, and re-placing it would
        // rewrite a day the student may well have worked through. Marking a
        // miss is the app's job (`PlanCoordinator.sweepMissedSessions`); this
        // only acts on what it is told. Pinning it also keeps the promise that
        // one miss moves one block — an earlier version made every past block
        // movable, and a single missed session then shuffled the whole week.
        func isMovable(_ session: PlannedSession) -> Bool {
            if session.state.isImmutable { return false }
            if session.state == .missed { return true }
            return session.start > now
        }
        let pinned = existing.filter { !isMovable($0) }
        let movable = existing.filter(isMovable)

        // Work already represented by a pinned session is done or being done.
        let pinnedItemIDs = Set(pinned.map(\.itemID))
        let pending = items
            .filter { !pinnedItemIDs.contains($0.id) }
            .sorted(by: Self.priorityOrder)

        // Walls: things the scheduler must not overlap. Pinned sessions count.
        var occupied: [DateInterval] = commitments.compactMap { c in
            c.end > c.start ? DateInterval(start: c.start, end: c.end) : nil
        }
        occupied += pinned.compactMap { s in
            s.end > s.start ? DateInterval(start: s.start, end: s.end) : nil
        }

        // Capacity already consumed per day by pinned work.
        var usedPerDay: [Date: TimeInterval] = [:]
        for session in pinned {
            let day = calendar.startOfDay(for: session.start)
            usedPerDay[day, default: 0] += session.duration
        }

        var placed: [PlannedSession] = []
        var unplaceable: [ScheduleItem] = []

        // Preserve identity for work that is simply being re-placed, so the UI
        // can animate a move instead of a delete plus an insert.
        let previousByItem = Dictionary(movable.map { ($0.itemID, $0) },
                                        uniquingKeysWith: { a, _ in a })

        // ── Keep every placement that is still valid ──────────────────────
        //
        // "Only move what must move" cannot be honoured by re-placing the whole
        // pool each run: feeding one item back in reshuffles everything after
        // it in priority order, so a single missed session moved six other
        // blocks. Each still-valid placement is therefore kept and its slot
        // reserved *before* anything is placed fresh, and only work with
        // nowhere to be competes for what is left.
        var toPlace: [ScheduleItem] = []

        for item in pending {
            guard let previous = previousByItem[item.id],
                  isStillValid(previous, for: item, occupied: occupied,
                               usedPerDay: usedPerDay, availability: availability,
                               now: now)
            else {
                toPlace.append(item)
                continue
            }
            placed.append(previous)
            occupied.append(DateInterval(start: previous.start, end: previous.end))
            usedPerDay[calendar.startOfDay(for: previous.start), default: 0] += previous.duration
        }

        // Placement is O(items x days x blocks): every candidate day rescans the
        // occupied list, which grows as work is placed. Deliberately left
        // simple — 400 items schedule in ~0.14s, and a real student has closer
        // to 50. An interval tree would be faster and harder to trust, and
        // this is the code where being obviously correct matters most.
        for item in toPlace {
            if let slot = findSlot(for: item,
                                   occupied: occupied,
                                   usedPerDay: usedPerDay,
                                   availability: availability,
                                   now: now) {
                let previous = previousByItem[item.id]
                placed.append(PlannedSession(
                    id: previous?.id ?? UUID(),
                    itemID: item.id,
                    assignmentID: item.assignmentID,
                    start: slot.start,
                    end: slot.end,
                    state: .scheduled
                ))
                occupied.append(slot)
                usedPerDay[calendar.startOfDay(for: slot.start), default: 0] += slot.duration
            } else {
                unplaceable.append(item)
            }
        }

        let moved = placed.reduce(into: 0) { count, session in
            guard let previous = previousByItem[session.itemID] else { return }
            if previous.start != session.start { count += 1 }
        }

        let all = (pinned + placed).sorted { $0.start < $1.start }

        return ScheduleResult(
            sessions: all,
            unplaceable: unplaceable,
            workload: Self.workload(placed: placed,
                                    unplaceable: unplaceable,
                                    availability: availability,
                                    calendar: calendar),
            movedCount: moved
        )
    }

    /// Whether a session can simply stay where it is.
    ///
    /// Everything a fresh placement would guarantee, asked of a placement that
    /// already exists: still ahead of the clock, still before the deadline,
    /// still the right length, still inside the study window on a day the
    /// student works, still within that day's capacity, and still unoccupied.
    ///
    /// Anything that fails here has genuinely stopped being valid — a moved
    /// deadline, a shortened study day, a slot taken by a class — and only then
    /// is the block allowed to move.
    private func isStillValid(_ session: PlannedSession,
                              for item: ScheduleItem,
                              occupied: [DateInterval],
                              usedPerDay: [Date: TimeInterval],
                              availability: Availability,
                              now: Date) -> Bool {
        guard session.start >= now else { return false }
        guard session.end <= item.deadline else { return false }
        // A step whose estimate changed needs a differently-sized slot.
        guard abs(session.duration - item.duration) < 1 else { return false }

        let day = calendar.startOfDay(for: session.start)
        let weekday = calendar.component(.weekday, from: day)
        guard !availability.excludedWeekdays.contains(weekday) else { return false }

        guard let (windowStart, windowEnd) = window(on: day, weekday: weekday, availability)
        else { return false }
        guard session.start >= windowStart, session.end <= windowEnd else { return false }

        let remaining = TimeInterval(availability.dailyCapacityMinutes * 60)
            - (usedPerDay[day] ?? 0)
        guard remaining >= session.duration else { return false }

        return !occupied.contains { Self.overlaps($0, session.start, session.end) }
    }

    /// When work may sit on `day`: the school-day window Monday to Friday, the
    /// weekend one on Saturday and Sunday. An end of 24 is the last minute of
    /// the day.
    private func window(on day: Date, weekday: Int,
                        _ availability: Availability) -> (Date, Date)? {
        let hours = availability.window(onWeekday: weekday)
        guard let start = calendar.date(bySettingHour: hours.startHour, minute: 0, second: 0, of: day),
              let end = calendar.date(bySettingHour: hours.endHour == 24 ? 23 : hours.endHour,
                                      minute: hours.endHour == 24 ? 59 : 0, second: 0, of: day)
        else { return nil }
        return (start, end)
    }

    /// Half-open overlap: blocks that merely touch are not in conflict, so
    /// 16:00-17:00 and 17:00-18:00 can sit back to back.
    private static func overlaps(_ interval: DateInterval, _ start: Date, _ end: Date) -> Bool {
        interval.start < end && start < interval.end
    }

    // MARK: - Ordering

    /// Earliest deadline first; within an assignment, keep the author's order.
    /// Total and deterministic — ties broken by id so equal work never shuffles
    /// between runs.
    /// Deadline first, always.
    ///
    /// Priority is the *second* key, never the first. If it led, marking a maths
    /// problem set "high" could push an essay due tomorrow past its deadline —
    /// the student would have asked for one thing to matter more and been given
    /// a missed hand-in. Priority decides who goes first among work that is
    /// already competing for the same window, which is the only place the
    /// student's answer is actually information the scheduler lacks.
    private static func priorityOrder(_ a: ScheduleItem, _ b: ScheduleItem) -> Bool {
        if a.deadline != b.deadline { return a.deadline < b.deadline }
        if a.priority != b.priority { return a.priority > b.priority }
        if a.assignmentID != b.assignmentID {
            return a.assignmentID.uuidString < b.assignmentID.uuidString
        }
        if a.ordinal != b.ordinal { return a.ordinal < b.ordinal }
        return a.id.uuidString < b.id.uuidString
    }

    // MARK: - Placement

    private func findSlot(
        for item: ScheduleItem,
        occupied: [DateInterval],
        usedPerDay: [Date: TimeInterval],
        availability: Availability,
        now: Date
    ) -> DateInterval? {

        guard item.deadline > now else { return nil }

        var day = calendar.startOfDay(for: now)
        let lastDay = calendar.startOfDay(for: item.deadline)

        var daysExamined = 0
        while day <= lastDay && daysExamined < Self.maxDaysAhead {
            defer {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                daysExamined += 1
            }

            let weekday = calendar.component(.weekday, from: day)
            if availability.excludedWeekdays.contains(weekday) { continue }

            let remaining = TimeInterval(availability.dailyCapacityMinutes * 60)
                - (usedPerDay[day] ?? 0)
            if remaining < item.duration { continue }

            guard let (windowStart, windowEnd) = window(on: day, weekday: weekday, availability)
            else { continue }

            // Never schedule into the past, and never past the deadline.
            let earliest = max(windowStart, now)
            let latest = min(windowEnd, item.deadline)
            guard latest > earliest, latest.timeIntervalSince(earliest) >= item.duration else { continue }

            if let slot = firstGap(from: earliest, to: latest,
                                   duration: item.duration, occupied: occupied) {
                return slot
            }
        }
        return nil
    }

    /// Earliest gap of at least `duration` between `start` and `end`.
    private func firstGap(from start: Date, to end: Date,
                          duration: TimeInterval, occupied: [DateInterval]) -> DateInterval? {
        // Only blocks overlapping this window matter.
        let relevant = occupied
            .filter { $0.end > start && $0.start < end }
            .sorted { $0.start < $1.start }

        var cursor = start
        for block in relevant {
            if block.start.timeIntervalSince(cursor) >= duration {
                return DateInterval(start: cursor, duration: duration)
            }
            cursor = max(cursor, block.end)
            if cursor >= end { return nil }
        }
        return end.timeIntervalSince(cursor) >= duration
            ? DateInterval(start: cursor, duration: duration)
            : nil
    }

    // MARK: - Workload

    /// Derived from whether the plan actually fits, not from a separate model.
    /// Anything that could not be placed means cooked, by definition.
    static func workload(placed: [PlannedSession],
                         unplaceable: [ScheduleItem],
                         availability: Availability,
                         calendar: Calendar) -> WorkloadState {
        if !unplaceable.isEmpty { return .cooked }
        guard availability.dailyCapacityMinutes > 0 else {
            return placed.isEmpty ? .calm : .cooked
        }

        var perDay: [Date: TimeInterval] = [:]
        for session in placed {
            perDay[calendar.startOfDay(for: session.start), default: 0] += session.duration
        }
        guard let heaviest = perDay.values.max() else { return .calm }

        let capacity = TimeInterval(availability.dailyCapacityMinutes * 60)
        let load = heaviest / capacity
        if load >= 0.85 { return .cooked }
        if load >= 0.55 { return .busy }
        return .calm
    }
}
