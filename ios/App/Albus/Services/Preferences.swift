import Foundation
import Observation
import AlbusCore

/// What the student told us about themselves, and what Albus plans with.
///
/// UserDefaults rather than SwiftData: these are a handful of scalars read on
/// every schedule, they are device settings rather than user content, and
/// putting them in the store would mean a migration every time one is added.
@Observable
@MainActor
final class Preferences {

    enum Program: String, CaseIterable, Identifiable, Sendable {
        case ib = "IB"
        case aLevel = "A-Level"
        case ap = "AP"
        case university = "University"
        case other = "Other"
        var id: String { rawValue }

        /// Albus plans for any student, so every programme is offered. It
        /// colours the wording Albus uses; nothing depends on it.
        static let offered: [Program] = allCases

    }

    /// The three buckets onboarding offers, mapped to real capacity.
    enum StudyLoad: String, CaseIterable, Identifiable, Sendable {
        case light, standard, heavy
        var id: String { rawValue }

        var title: String {
            switch self {
            case .light: "Under 2h"
            case .standard: "2 to 4h"
            case .heavy: "4h plus"
            }
        }

        /// The middle of each bucket, in minutes. A student who says "2 to 4"
        /// is told three hours of work fits, not four — a plan that is always
        /// slightly achievable beats one that is occasionally impossible.
        var dailyCapacityMinutes: Int {
            switch self {
            case .light: 90
            case .standard: 180
            case .heavy: 270
            }
        }
    }

    private enum Key {
        static let name = "albus.profile.name"
        static let program = "albus.profile.program"
        static let board = "albus.profile.board"
        static let load = "albus.profile.load"
        static let onboarded = "albus.profile.onboarded"
        static let windowStart = "albus.profile.windowStart"
        static let windowEnd = "albus.profile.windowEnd"
        static let daysOff = "albus.profile.daysOff"
        static let notify = "albus.notify.enabled"
        static let serious = "albus.notify.serious"
        static let briefHour = "albus.notify.briefHour"
        static let briefMinute = "albus.notify.briefMinute"
        static let nudge = "albus.notify.nudge"
        static let warn72 = "albus.notify.warn72"
        static let warn24 = "albus.notify.warn24"
        static let warn3 = "albus.notify.warn3"
        static let quietStart = "albus.notify.quietStart"
        static let quietEnd = "albus.notify.quietEnd"
        static let maxPerDay = "albus.notify.maxPerDay"
    }

    /// Kept so a value written by an older build still decodes. Nothing reads
    /// it now: exam boards only ever distinguished A-level specifications.
    nonisolated static let defaultExamBoard = "AQA"


    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        name = defaults.string(forKey: Key.name) ?? ""
        program = Program(rawValue: defaults.string(forKey: Key.program) ?? "") ?? .other
        examBoard = defaults.string(forKey: Key.board) ?? Self.defaultExamBoard
        load = StudyLoad(rawValue: defaults.string(forKey: Key.load) ?? "") ?? .standard
        hasOnboarded = defaults.bool(forKey: Key.onboarded)

        // `object(forKey:)` rather than `integer(forKey:)`: an unset integer key
        // reads back as 0, which is a legitimate hour and would silently move
        // every existing student's study window to midnight.
        windowStartHour = defaults.object(forKey: Key.windowStart) as? Int
            ?? Availability.default.windowStartHour
        windowEndHour = defaults.object(forKey: Key.windowEnd) as? Int
            ?? Availability.default.windowEndHour
        daysOff = Set(defaults.array(forKey: Key.daysOff) as? [Int] ?? [])

        let fallback = NotificationSettings.default
        // `bool(forKey:)` on an unset key is false, which would ship every new
        // student a silent app — so the two that default to on read through
        // `object(forKey:)` and fall back to true.
        notificationsEnabled = defaults.object(forKey: Key.notify) as? Bool ?? true
        nudgeEnabled = defaults.object(forKey: Key.nudge) as? Bool ?? true
        warnAt24h = defaults.object(forKey: Key.warn24) as? Bool ?? fallback.warnAt24h
        warnAt3h = defaults.object(forKey: Key.warn3) as? Bool ?? fallback.warnAt3h
        seriousMode = defaults.bool(forKey: Key.serious)
        warnAt72h = defaults.bool(forKey: Key.warn72)
        briefHour = defaults.object(forKey: Key.briefHour) as? Int ?? fallback.briefHour
        briefMinute = defaults.object(forKey: Key.briefMinute) as? Int ?? fallback.briefMinute
        quietStartHour = defaults.object(forKey: Key.quietStart) as? Int ?? fallback.quietStartHour
        quietEndHour = defaults.object(forKey: Key.quietEnd) as? Int ?? fallback.quietEndHour
        maxPerDay = defaults.object(forKey: Key.maxPerDay) as? Int ?? fallback.maxPerDay
    }

    var name: String { didSet { defaults.set(name, forKey: Key.name) } }
    var program: Program { didSet { defaults.set(program.rawValue, forKey: Key.program) } }
    /// Only meaningful for A-level. Stored regardless so switching programme and
    /// back does not silently reset it.
    var examBoard: String { didSet { defaults.set(examBoard, forKey: Key.board) } }
    var load: StudyLoad { didSet { defaults.set(load.rawValue, forKey: Key.load) } }

    /// Set only once onboarding has actually produced an account, so a flow
    /// abandoned halfway is resumed rather than skipped.
    private(set) var hasOnboarded: Bool

    func markOnboarded() {
        hasOnboarded = true
        defaults.set(true, forKey: Key.onboarded)
    }

    func resetAfterAccountDeletion() {
        name = ""
        program = .other
        examBoard = Self.defaultExamBoard
        load = .standard
        windowStartHour = Availability.default.windowStartHour
        windowEndHour = Availability.default.windowEndHour
        daysOff = []
        hasOnboarded = false
        defaults.removeObject(forKey: Key.onboarded)
    }

    /// When the student is willing to work.
    ///
    /// These existed on `Availability` from the start and were never set, so
    /// every student in the app studied 16:00–22:00, seven days a week, with no
    /// way to say otherwise. The defaults deliberately match what was hardcoded,
    /// so nobody's existing plan moves until they actually change something.
    var windowStartHour: Int {
        didSet { defaults.set(windowStartHour, forKey: Key.windowStart) }
    }
    var windowEndHour: Int {
        didSet { defaults.set(windowEndHour, forKey: Key.windowEnd) }
    }
    /// Weekday numbers entirely off, 1 = Sunday per `Calendar`.
    var daysOff: Set<Int> {
        didSet { defaults.set(Array(daysOff).sorted(), forKey: Key.daysOff) }
    }

    /// What the scheduler plans against.
    ///
    /// `Availability`'s own initialiser clamps and orders the hours, so a stored
    /// value that is out of range or inverted cannot reach the scheduler.
    ///
    /// The weekday set it does *not* guard, and a set containing all seven days
    /// leaves the scheduler with nowhere to place anything: every step reports
    /// unplaceable, forever, with no way back except finding the setting again.
    /// These values live in `UserDefaults`, which is writable by anything with
    /// access to the container, so the guard belongs here rather than in the
    /// screen that happens to edit them today.
    var availability: Availability {
        Availability(
            windowStartHour: windowStartHour,
            windowEndHour: windowEndHour,
            dailyCapacityMinutes: load.dailyCapacityMinutes,
            excludedWeekdays: Self.sanitisedDaysOff(daysOff)
        )
    }

    /// Valid weekday numbers only, and never all of them.
    nonisolated static func sanitisedDaysOff(_ raw: Set<Int>) -> Set<Int> {
        let valid = raw.filter { (1...7).contains($0) }
        return valid.count >= 7 ? [] : valid
    }

    // MARK: - Notifications

    /// The app's own switch, separate from the system permission.
    ///
    /// Two switches rather than one because they answer different questions:
    /// iOS asks whether Albus may ever speak, this asks whether it should.
    /// Turning this off has to be possible without sending the student into
    /// system settings.
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Key.notify) } }
    /// Drops the register to the app's dry voice everywhere it is allowed to
    /// vary. The escape hatch for a student who wants a planner, not a cactus.
    var seriousMode: Bool { didSet { defaults.set(seriousMode, forKey: Key.serious) } }
    var briefHour: Int { didSet { defaults.set(briefHour, forKey: Key.briefHour) } }
    var briefMinute: Int { didSet { defaults.set(briefMinute, forKey: Key.briefMinute) } }
    var nudgeEnabled: Bool { didSet { defaults.set(nudgeEnabled, forKey: Key.nudge) } }
    var warnAt72h: Bool { didSet { defaults.set(warnAt72h, forKey: Key.warn72) } }
    var warnAt24h: Bool { didSet { defaults.set(warnAt24h, forKey: Key.warn24) } }
    var warnAt3h: Bool { didSet { defaults.set(warnAt3h, forKey: Key.warn3) } }
    var quietStartHour: Int { didSet { defaults.set(quietStartHour, forKey: Key.quietStart) } }
    var quietEndHour: Int { didSet { defaults.set(quietEndHour, forKey: Key.quietEnd) } }
    var maxPerDay: Int { didSet { defaults.set(maxPerDay, forKey: Key.maxPerDay) } }

    /// What the notification planner reads. Clamped by the value type's own
    /// initialiser, so a stored value out of range cannot reach it.
    var notificationSettings: NotificationSettings {
        NotificationSettings(
            enabled: notificationsEnabled,
            seriousMode: seriousMode,
            briefHour: briefHour,
            briefMinute: briefMinute,
            nudgeEnabled: nudgeEnabled,
            warnAt72h: warnAt72h,
            warnAt24h: warnAt24h,
            warnAt3h: warnAt3h,
            quietStartHour: quietStartHour,
            quietEndHour: quietEndHour,
            maxPerDay: maxPerDay
        )
    }

    /// Used only for the greeting. Empty is fine and common.
    var firstName: String {
        name.split(separator: " ").first.map(String.init) ?? ""
    }
}
