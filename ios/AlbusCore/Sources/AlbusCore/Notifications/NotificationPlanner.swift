import Foundation

/// Decides everything Albus will say, and when.
///
/// Pure: a context goes in, a list of fully-rendered notifications comes out.
/// It imports no `UserNotifications`, touches no store and reads no clock — the
/// time is in the context. That is what lets every policy question here (quiet
/// hours, the daily cap, the 64-slot budget, DST) be answered by a test with no
/// simulator, which is the same reason `Scheduler` is built this way.
public struct NotificationPlanner: Sendable {

    /// iOS keeps only the **64 soonest-firing** pending local notifications per
    /// app and silently discards the rest — permanently, not until space frees.
    /// Planning to 48 leaves room for the focus-session alert, which is owned
    /// by `FocusSession` and must never be evicted by a re-plan.
    public static let budget = 48

    /// How many days ahead the daily kinds are pre-rendered.
    ///
    /// A repeating trigger would cost one slot forever, but its content freezes
    /// at registration — it can never name today's actual step. Three real days
    /// plus the dormancy notification as the tail is the honest version.
    public static let horizonDays = 3

    private let calendar: Calendar

    public init(calendar: Calendar = Scheduler.defaultCalendar) {
        self.calendar = calendar
    }

    // MARK: - Entry point

    public func plan(_ context: NotificationContext) -> [PlannedNotification] {
        guard context.settings.enabled else { return [] }

        let candidates = allCandidates(context)
        let settled = candidates.compactMap { settle($0, context) }
        let allowed = applyPause(settled, context)
        let deduped = dedupeBySlot(allowed)
        let spaced = spaceOutSameAssignment(deduped)
        let capped = enforceDailyCap(spaced, maxPerDay: context.settings.maxPerDay)
        let budgeted = applyBudget(capped)

        return render(budgeted, context)
    }

    // MARK: - Candidates
    //
    // Each candidate is a kind, a preferred moment and the assignment it is
    // about. Nothing here worries about quiet hours, caps or budget — those are
    // separate passes so each can be tested on its own.

    struct Candidate {
        let kind: NotificationKind
        let fireDate: Date
        let assignment: NotificationAssignment?
        /// Bounds how far a candidate may be pushed. A warning that settles
        /// past the thing it is warning about is worse than silence.
        let notAfter: Date?
        let identifier: String
    }

    private func allCandidates(_ context: NotificationContext) -> [Candidate] {
        var out: [Candidate] = []
        out += dailyCandidates(context)
        out += deadlineCandidates(context)
        out += unfitCandidates(context)
        out += engagementCandidates(context)
        return out
    }

    /// Morning briefs, nudges, hand-in warnings and the weekly momentum line.
    private func dailyCandidates(_ context: NotificationContext) -> [Candidate] {
        var out: [Candidate] = []
        let open = context.assignments.filter { !$0.isComplete }

        for offset in 0...Self.horizonDays {
            guard let day = calendar.date(byAdding: .day, value: offset,
                                          to: calendar.startOfDay(for: context.now)),
                  let brief = time(context.settings.briefHour,
                                   context.settings.briefMinute, on: day)
            else { continue }

            let key = dayKey(day)
            let blocksToday = context.blocks.filter { calendar.isDate($0.start, inSameDayAs: day) }
            let dueToday = open.filter { calendar.isDate($0.deadline, inSameDayAs: day) }

            // Due today beats the brief. Both want the same moment, and a
            // student with something due does not need to be told the weather.
            if let due = dueToday.min(by: { $0.deadline < $1.deadline }) {
                out.append(Candidate(kind: .handInToday, fireDate: brief,
                                     assignment: due, notAfter: due.deadline,
                                     identifier: "albus.plan.handin.\(due.id.uuidString).\(key)"))
            } else if !blocksToday.isEmpty {
                // Only on a day that actually has work in it. Briefing a day
                // with nothing scheduled produced lines like "0 minutes across
                // 0 steps", and "here is your empty day" is not worth a
                // notification — dormancy and the deadline ladder cover the
                // student who has work but nothing planned today.
                out.append(Candidate(
                    kind: .morningBrief, fireDate: brief,
                    // Still ahead of *this* brief, not merely ahead of now: a
                    // brief three days out would otherwise cheerfully describe
                    // a deadline that has passed by the time it arrives.
                    assignment: open.filter { $0.deadline >= brief }
                        .min(by: { $0.deadline < $1.deadline }),
                    notAfter: nil,
                    identifier: "albus.plan.brief.\(key)"))
            }

            // The nudge anchors on the first real block, not on the window
            // start — a block at 19:00 nudged at 16:00 is three hours early and
            // reads as noise.
            if context.settings.nudgeEnabled,
               let first = blocksToday.min(by: { $0.start < $1.start }) {
                out.append(Candidate(kind: .windowNudge, fireDate: first.start,
                                     assignment: open.first { $0.id == first.assignmentID },
                                     notAfter: first.start.addingTimeInterval(3600),
                                     identifier: "albus.plan.nudge.\(key)"))
            }

            // Momentum only on a Sunday with nothing scheduled, so it can never
            // take the slot a real plan needed.
            if calendar.component(.weekday, from: day) == 1,
               blocksToday.isEmpty, dueToday.isEmpty,
               context.weeklyFocusedMinutes > 0 {
                out.append(Candidate(kind: .momentum, fireDate: brief,
                                     assignment: nil, notAfter: nil,
                                     identifier: "albus.plan.momentum.\(key)"))
            }
        }
        return out
    }

    /// The T-72 / T-24 / T-3 ladder, plus anything already late.
    private func deadlineCandidates(_ context: NotificationContext) -> [Candidate] {
        var out: [Candidate] = []
        let settings = context.settings

        for assignment in context.assignments where !assignment.isComplete {
            if assignment.deadline < context.now {
                // Overdue is announced at the next brief, not the instant it
                // lapses — which is usually the middle of the night.
                if let next = nextBriefTime(after: context.now, settings: settings) {
                    out.append(Candidate(
                        kind: .overdue, fireDate: next, assignment: assignment,
                        notAfter: nil,
                        identifier: "albus.plan.overdue.\(assignment.id.uuidString).\(dayKey(next))"
                    ))
                }
                continue
            }

            guard assignment.remainingSteps > 0 else { continue }

            let tiers: [(NotificationKind, Bool, TimeInterval)] = [
                (.deadline72, settings.warnAt72h, 72 * 3600),
                (.deadline24, settings.warnAt24h, 24 * 3600),
                (.deadline03, settings.warnAt3h, 3 * 3600)
            ]

            for (kind, enabled, lead) in tiers where enabled {
                let fire = assignment.deadline.addingTimeInterval(-lead)
                // The hand-in-day notification already covers the last morning.
                guard !calendar.isDate(fire, inSameDayAs: assignment.deadline)
                        || kind == .deadline03 else { continue }
                out.append(Candidate(
                    kind: kind, fireDate: fire, assignment: assignment,
                    notAfter: assignment.deadline,
                    identifier: "albus.plan.\(kind.rawValue).\(assignment.id.uuidString)"
                ))
            }
        }
        return out
    }

    /// The one no other planner can send: the work no longer fits.
    ///
    /// Fires on a **transition**, never on the standing state. `unplaceable` is
    /// trivially easy to trip — a single step longer than one day's window is
    /// unplaceable even with a month of runway — so alarming whenever the set
    /// is non-empty would mean alarming forever.
    private func unfitCandidates(_ context: NotificationContext) -> [Candidate] {
        guard !context.unplaceableSignature.isEmpty,
              context.unplaceableSignature != context.previousUnplaceableSignature,
              let worst = context.assignments
                  .filter({ $0.hasUnplaceable && !$0.isComplete })
                  .min(by: { $0.deadline < $1.deadline })
        else { return [] }

        // Not instantly: the student is often looking at the screen that caused
        // it, and a notification about what they just did is noise.
        let fire = context.now.addingTimeInterval(15 * 60)
        return [Candidate(
            kind: .planStoppedFitting, fireDate: fire, assignment: worst,
            notAfter: worst.deadline,
            identifier: "albus.plan.unfit.\(context.unplaceableSignature)"
        )]
    }

    /// Nothing has happened for a while.
    private func engagementCandidates(_ context: NotificationContext) -> [Candidate] {
        guard context.assignments.contains(where: { !$0.isComplete }) else { return [] }
        var out: [Candidate] = []

        // While paused, the only thing worth saying is that Albus is pausing.
        if let paused = context.pausedUntil, paused > context.now {
            if let fire = nextBriefTime(after: context.now, settings: context.settings) {
                out.append(Candidate(kind: .backOff, fireDate: fire, assignment: nil,
                                     notAfter: nil,
                                     identifier: "albus.plan.backoff.\(dayKey(paused))"))
            }
            return out
        }

        for (days, kind) in [(3, NotificationKind.dormantSoft), (7, .dormantFinal)] {
            guard let day = calendar.date(byAdding: .day, value: days, to: context.lastOpened),
                  let fire = time(context.settings.briefHour, context.settings.briefMinute,
                                  on: calendar.startOfDay(for: day))
            else { continue }
            out.append(Candidate(kind: kind, fireDate: fire, assignment: nil,
                                 notAfter: nil,
                                 identifier: "albus.plan.dormant.\(days)"))
        }
        return out
    }

    // MARK: - Settling

    /// Moves a candidate out of quiet hours, or drops it.
    ///
    /// **Forward only, and never past what it is about.** A T-3h warning for a
    /// 23:00 deadline would otherwise be pushed to 07:00 the next morning and
    /// arrive after the hand-in — technically delivered, entirely useless.
    func settle(_ candidate: Candidate, _ context: NotificationContext) -> Candidate? {
        let settings = context.settings
        guard candidate.fireDate > context.now else { return nil }
        guard let moved = movedOutOfQuietHours(candidate.fireDate, settings) else { return nil }
        guard moved > context.now else { return nil }
        if let limit = candidate.notAfter, moved > limit { return nil }

        return Candidate(kind: candidate.kind, fireDate: moved,
                         assignment: candidate.assignment, notAfter: candidate.notAfter,
                         identifier: candidate.identifier)
    }

    func isQuiet(_ date: Date, _ settings: NotificationSettings) -> Bool {
        guard settings.quietStartHour != settings.quietEndHour else { return false }
        let hour = calendar.component(.hour, from: date)
        return settings.quietStartHour < settings.quietEndHour
            ? (hour >= settings.quietStartHour && hour < settings.quietEndHour)
            : (hour >= settings.quietStartHour || hour < settings.quietEndHour)
    }

    func movedOutOfQuietHours(_ date: Date, _ settings: NotificationSettings) -> Date? {
        guard isQuiet(date, settings) else { return date }
        let hour = calendar.component(.hour, from: date)
        // Before the end hour means still the same night; after the start hour
        // means the quiet period runs into tomorrow.
        let base = hour < settings.quietEndHour
            ? date
            : calendar.date(byAdding: .day, value: 1, to: date)
        guard let base else { return nil }
        // Nil on a DST gap, where the hour genuinely does not exist. Dropping is
        // right: the same guard is what `Scheduler` does with its window.
        return calendar.date(bySettingHour: settings.quietEndHour, minute: 0, second: 0, of: base)
    }

    // MARK: - Filtering passes

    /// While backed off, only real consequences get through.
    private func applyPause(_ candidates: [Candidate],
                            _ context: NotificationContext) -> [Candidate] {
        guard let paused = context.pausedUntil, paused > context.now else { return candidates }
        return candidates.filter { $0.kind.tier == 1 || $0.kind == .backOff }
    }

    /// One notification per competing moment per day.
    ///
    /// Everything anchored to the brief hour shares a slot, so a hand-in
    /// warning replaces the brief rather than arriving beside it.
    private func dedupeBySlot(_ candidates: [Candidate]) -> [Candidate] {
        var best: [String: Candidate] = [:]
        var free: [Candidate] = []

        for candidate in candidates {
            guard candidate.kind.slot != .free else { free.append(candidate); continue }
            let key = "\(candidate.kind.slot)|\(dayKey(candidate.fireDate))"
            guard let held = best[key] else { best[key] = candidate; continue }
            if isBetter(candidate, than: held) { best[key] = candidate }
        }
        return free + Array(best.values)
    }

    /// Never two notifications about the same assignment within a few hours.
    ///
    /// Found by reading real output rather than by a test: a 09:00 deadline put
    /// its T-3h at 06:00, quiet hours moved that to 07:00, and the hand-in-day
    /// warning was already at 07:30 — the same assignment twice, half an hour
    /// apart, saying almost the same thing. Escalation across a day is useful;
    /// two in a row is the reason people turn notifications off.
    private func spaceOutSameAssignment(_ candidates: [Candidate]) -> [Candidate] {
        let minimumGap: TimeInterval = 3 * 3600
        var kept: [Candidate] = []

        for candidate in candidates.sorted(by: { isBetter($0, than: $1) }) {
            guard let assignment = candidate.assignment else { kept.append(candidate); continue }
            let crowded = kept.contains {
                $0.assignment?.id == assignment.id
                    && abs($0.fireDate.timeIntervalSince(candidate.fireDate)) < minimumGap
            }
            // Sorted best-first, so whatever is already kept outranks this.
            if !crowded { kept.append(candidate) }
        }
        return kept
    }

    /// Lower tier wins; then earlier; then by identifier, so the result cannot
    /// depend on the order candidates happened to be generated in.
    private func isBetter(_ lhs: Candidate, than rhs: Candidate) -> Bool {
        if lhs.kind.tier != rhs.kind.tier { return lhs.kind.tier < rhs.kind.tier }
        if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
        return lhs.identifier < rhs.identifier
    }

    /// The student's volume preference.
    ///
    /// **Tier 1 is exempt, deliberately.** The cap describes how often Albus may
    /// *nudge*; suppressing "this is due today" or "your plan no longer fits" to
    /// honour a volume setting would be the app failing at the job it exists to
    /// do. Slot deduplication already guarantees at most one of those per day,
    /// so the exemption cannot become a flood.
    func enforceDailyCap(_ candidates: [Candidate], maxPerDay: Int) -> [Candidate] {
        let urgent = candidates.filter { $0.kind.tier == 1 }
        let rest = candidates.filter { $0.kind.tier != 1 }

        var perDay: [Date: Int] = [:]
        var kept: [Candidate] = []

        for candidate in rest.sorted(by: { isBetter($0, than: $1) }) {
            let day = calendar.startOfDay(for: candidate.fireDate)
            let used = perDay[day] ?? 0
            guard used < maxPerDay else { continue }
            perDay[day] = used + 1
            kept.append(candidate)
        }
        return urgent + kept
    }

    /// The 64-slot ceiling, applied explicitly rather than left to iOS.
    ///
    /// Free-tier students cap at three active assignments and land nowhere near
    /// this. Plus is uncapped: fifteen assignments would want more slots than
    /// exist, and iOS would drop the furthest-out ones with no signal at all.
    /// Choosing here means the nearest deadlines always survive.
    func applyBudget(_ candidates: [Candidate]) -> [Candidate] {
        let ordered = candidates.sorted(by: { isBetter($0, than: $1) })
        guard ordered.count > Self.budget else { return ordered }
        // Never silent: the house rule is that a truncation says so.
        print("[Albus] notification budget: keeping \(Self.budget) of \(ordered.count); "
              + "dropped \(ordered.count - Self.budget) lowest-priority")
        return Array(ordered.prefix(Self.budget))
    }

    // MARK: - Rendering

    private func render(_ candidates: [Candidate],
                        _ context: NotificationContext) -> [PlannedNotification] {
        // Within one plan only, never across rebuilds.
        //
        // This started as a persisted list of recently-used lines, which made
        // every rebuild produce different copy for notifications that had not
        // changed: new text, new fingerprint, and the diff re-wrote the entire
        // pending set every time anything at all happened. The seed is already
        // unique per (notification, day), so variety across days comes for free
        // and stably; this only stops one plan repeating itself within itself.
        var used: [String] = []
        var out: [PlannedNotification] = []

        // Stable order in, stable order out — and a stable order is what makes
        // the no-repeat window behave the same way twice.
        for candidate in candidates.sorted(by: { isBetter($0, than: $1) }) {
            let facts = facts(for: candidate, context)
            let requested: Register = context.settings.seriousMode ? .plain : .chaos
            let options = NotificationCopy.candidates(
                kind: candidate.kind, workload: context.workload,
                register: requested, facts: facts
            )
            let seed = StableHash.value(
                "\(candidate.identifier)|\(candidate.kind.rawValue)|\(dayKey(candidate.fireDate))"
            )
            guard let template = NotificationCopy.pick(from: options, recent: used, seed: seed),
                  let text = NotificationCopy.render(template, facts: facts)
            else { continue }

            used.append(template.id)
            out.append(PlannedNotification(
                id: candidate.identifier,
                kind: candidate.kind,
                fireDate: candidate.fireDate,
                title: text.title,
                body: text.body,
                threadID: candidate.assignment.map { "albus.assignment.\($0.id.uuidString)" },
                mood: context.workload,
                templateID: template.id
            ))
        }
        return out
    }

    /// Fills in the numbers a line will quote.
    ///
    /// **Everything time-relative is measured from the moment the notification
    /// will actually arrive, never from the moment it was planned.** Planning
    /// happens once and covers days; a T-3h warning composed at planning time
    /// read "Bio IA in 80h" because that was true when the plan was built and
    /// nonsense by the time it fired. Same for "due in 3 days" arriving on the
    /// morning it is due.
    private func facts(for candidate: Candidate, _ context: NotificationContext) -> Facts {
        var facts = Facts()
        let when = candidate.fireDate
        let open = context.assignments.filter { !$0.isComplete }
        // Every line that uses `{count}` puts a plural after it: "{count}
        // assignments are still open". So the fact is offered only for a
        // number that reads as a plural, and one open assignment gets a line
        // that does not count. It said "1 assignments are still open".
        facts[.count] = Self.countable(open.count)

        if let assignment = candidate.assignment {
            facts[.assignment] = assignment.title
            facts[.steps] = plural(assignment.remainingSteps, "step")
            facts[.minutes] = durationPhrase(assignment.remainingMinutes)
            facts[.days] = dayPhrase(from: when, to: assignment.deadline)
            facts[.hours] = plural(max(0, hours(from: when, to: assignment.deadline)), "hour")
            if let step = assignment.nextStepTitle { facts[.step] = step }
            if assignment.deadline < when {
                facts[.lateBy] = lateDescription(assignment.deadline, when)
            }
        }

        switch candidate.kind {
        case .morningBrief:
            // The brief describes the *day*, so its numbers come from that
            // day's blocks rather than from any one assignment.
            let today = context.blocks.filter { calendar.isDate($0.start, inSameDayAs: when) }
            facts[.minutes] = durationPhrase(today.reduce(0) { $0 + $1.minutes })
            facts[.steps] = plural(today.count, "step")
            facts[.step] = today.min(by: { $0.start < $1.start })?.stepTitle

        case .windowNudge:
            guard let first = context.blocks
                .filter({ calendar.isDate($0.start, inSameDayAs: when) })
                .min(by: { $0.start < $1.start }) else { break }
            facts[.step] = first.stepTitle
            facts[.minutes] = durationPhrase(first.minutes)
            facts[.assignment] = first.assignmentTitle

        case .planStoppedFitting:
            // As above: "1 steps can't be scheduled" for a single step.
            facts[.count] = Self.countable(context.unplaceableCount)

        case .momentum:
            facts[.weekMinutes] = durationPhrase(context.weeklyFocusedMinutes)

        case .dormantSoft, .dormantFinal:
            // A day or more after this reminder, not merely the nearest: these
            // fire days after the plan was made, and an assignment overdue or
            // due later that day by then read "One week Sci in today". With
            // nothing that far ahead, no assignment is named, and only the
            // lines that need none can be picked.
            if let nearest = open.filter({ days(from: when, to: $0.deadline) >= 1 })
                .min(by: { $0.deadline < $1.deadline }) {
                facts[.assignment] = nearest.title
                facts[.days] = dayPhrase(from: when, to: nearest.deadline)
            }

        default:
            break
        }
        return facts
    }

    /// A number for `{count}`, or nil for exactly one: the lines that use it
    /// are written for several, and a line without it is picked instead.
    static func countable(_ number: Int) -> String? {
        number == 1 ? nil : String(number)
    }

    /// "1 step", "3 steps". A lock screen saying "1 days" looks like a bug
    /// because it is one.
    private func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    /// Minutes below an hour and a half, hours and minutes above it.
    ///
    /// A whole assignment's remaining work is routinely hundreds of minutes,
    /// and "1220 minutes of work, one evening" was a real line — technically
    /// correct, unreadable, and it makes the app look like it cannot count.
    private func durationPhrase(_ minutes: Int) -> String {
        guard minutes >= 90 else { return plural(minutes, "minute") }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? plural(hours, "hour") : "\(hours)h \(rest)m"
    }

    /// Never "the past".
    ///
    /// Every template using this reads "{assignment} in {days}", so a negative
    /// value produced "Sci is the past out and today owes it 162 minutes".
    /// The lines that use it pass only deadlines on a later day than the fire
    /// date, and an overdue assignment has its own kind, with its own corpus.
    /// The clamp is a backstop, not a phrasing: "in today" still reads wrong.
    private func dayPhrase(from: Date, to: Date) -> String {
        switch days(from: from, to: to) {
        case ..<1: return "today"
        case 1: return "1 day"
        case let n: return "\(n) days"
        }
    }

    // MARK: - Small helpers

    private func time(_ hour: Int, _ minute: Int, on day: Date) -> Date? {
        calendar.date(bySettingHour: hour, minute: minute, second: 0,
                      of: calendar.startOfDay(for: day))
    }

    private func nextBriefTime(after date: Date, settings: NotificationSettings) -> Date? {
        guard let today = time(settings.briefHour, settings.briefMinute, on: date) else { return nil }
        if today > date { return today }
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return time(settings.briefHour, settings.briefMinute, on: tomorrow)
    }

    private func days(from: Date, to: Date) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: from),
                                to: calendar.startOfDay(for: to)).day ?? 0
    }

    private func hours(from: Date, to: Date) -> Int {
        Int(to.timeIntervalSince(from) / 3600)
    }

    private func lateDescription(_ deadline: Date, _ now: Date) -> String {
        let late = days(from: deadline, to: now)
        switch late {
        case ..<1: return "today"
        case 1: return "yesterday"
        default: return "\(late) days ago"
        }
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
