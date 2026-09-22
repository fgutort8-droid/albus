import Foundation

/// What kind of work a task is.
///
/// **Why this type exists at all.** This list was previously written out twice
/// — a six-case enum in `OnboardingFlow` and an eight-entry array of string
/// tuples in `AddTaskSheet` — and the two had already drifted apart: onboarding
/// was quietly missing `presentation` and `other`. A student could pick a type
/// when adding a task that they could not pick during onboarding, for no
/// reason anyone chose. One list, in one place, is how that stops.
///
/// **The raw values are a wire contract**, not display strings. They are
/// checked by `assignments_task_type_check` in Postgres and by `TASK_TYPES` in
/// `supabase/functions/_shared/task_type.ts`, which the breakdown Edge Function
/// uses. All three lists have to agree; a value here that the server does not
/// know is a 422 the student cannot do anything about. Change one, change all
/// three.
enum TaskType: String, CaseIterable, Identifiable, Sendable, Codable {

    case essay
    case problemSet = "problem_set"
    case labReport = "lab_report"
    case reading
    case revision
    case project
    case presentation
    case other

    var id: String { rawValue }

    /// What the student sees.
    var title: String {
        switch self {
        case .essay:        "Essay"
        case .problemSet:   "Problem set"
        case .labReport:    "Lab report"
        case .reading:      "Reading"
        case .revision:     "Revision"
        case .project:      "Project"
        case .presentation: "Presentation"
        case .other:        "Other"
        }
    }

    /// A sensible default duration, in minutes, when the student has not said.
    ///
    /// These are starting estimates the estimator refines from real completion
    /// data — see `AlbusCore`'s estimator — not claims about total effort. The
    /// scheduler places sessions, so a long project defaults to a long session,
    /// not to the whole project.
    var defaultMinutes: Int {
        switch self {
        case .reading:                    45
        case .revision:                   60
        case .problemSet, .presentation:  90
        case .essay, .labReport, .other:  120
        case .project:                    150
        }
    }
}

extension TaskType {

    /// The types offered when a student is picking one themselves: all of them,
    /// in declaration order.
    static var offered: [TaskType] { allCases }

    /// Decoding a value this build does not know.
    ///
    /// Falls back rather than failing: a task the student can see and work on,
    /// minus a precise label, beats an error on a screen they cannot fix. That
    /// covers a newer build's type, and also the six IB types this app offered
    /// until September 2026 (`internal_assessment`, `mock_exam`, …), which a
    /// task saved on the device before then can still hold. The server's copies
    /// were converted by migration `20260917120000_retire_ib_schema`.
    init(storedValue: String?) {
        self = storedValue.flatMap(TaskType.init(rawValue:)) ?? .other
    }
}
