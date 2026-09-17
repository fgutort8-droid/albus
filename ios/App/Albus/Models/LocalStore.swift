import Foundation
import SwiftData
import AlbusCore

// SwiftData models live in the app target, not in AlbusCore, so the scheduler
// and estimator stay free of persistence. They are transcribed from the
// Postgres schema rather than designed here — same names, same types, same
// nullability — because two independently-invented schemas is how a sync layer
// becomes a migration problem.

@Model
final class Course {
    #Index<Course>([\.remoteID])
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var displayName: String
    /// Stored as the token's raw value so a rename in the enum is a compile
    /// error rather than silent data corruption.
    var colorKey: String
    var courseTemplateID: UUID?
    var createdAt: Date

    @Relationship(deleteRule: .cascade, inverse: \Assignment.course)
    var assignments: [Assignment] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, displayName: String,
         colorKey: Tokens.SubjectColor = .violet, courseTemplateID: UUID? = nil,
         createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.displayName = displayName
        self.colorKey = colorKey.rawValue
        self.courseTemplateID = courseTemplateID
        self.createdAt = createdAt
    }

    /// Subject colour is a property of the course, never of the card showing
    /// it. Views read this and never pick a colour themselves.
    var subjectColor: Tokens.SubjectColor {
        Tokens.SubjectColor(rawValue: colorKey) ?? .violet
    }
}

@Model
final class Assignment {
    #Index<Assignment>([\.deadline], [\.status])
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var title: String
    var notes: String?
    var taskType: String
    var deadline: Date
    var estimatedMinutes: Int
    var status: String
    /// One of `AssignmentPriority`. Stored raw so a rename in the enum is a
    /// compile error here rather than a silent migration.
    ///
    /// Defaulted in the declaration, not just the initialiser: SwiftData needs a
    /// value for rows written before this column existed.
    var priority: String = AssignmentPriority.normal.rawValue
    var createdAt: Date
    var updatedAt: Date

    var course: Course?
    /// The rubric this is marked against. Nil is normal — plenty of work has no
    /// rubric, and refusing to plan without one would be worse than planning
    /// without one.
    var rubric: Rubric?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.assignment)
    var subtasks: [Subtask] = []

    /// Every time this work has been marked. Kept so a student can compare a
    /// draft against the version they handed in.
    @Relationship(deleteRule: .cascade, inverse: \Grading.assignment)
    var gradings: [Grading] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, title: String, notes: String? = nil,
         taskType: String = "other", deadline: Date, estimatedMinutes: Int,
         status: AssignmentStatus = .active,
         priority: AssignmentPriority = .normal,
         course: Course? = nil, rubric: Rubric? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.notes = notes
        self.taskType = taskType
        self.deadline = deadline
        self.estimatedMinutes = estimatedMinutes
        self.status = status.rawValue
        self.priority = priority.rawValue
        self.course = course
        self.rubric = rubric
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    /// Computed once here and read everywhere, rather than recomputed per view.
    var progress: Double {
        guard !subtasks.isEmpty else { return 0 }
        return Double(subtasks.filter { $0.completedAt != nil }.count) / Double(subtasks.count)
    }

    var isComplete: Bool {
        !subtasks.isEmpty && subtasks.allSatisfy { $0.completedAt != nil }
    }

    var priorityValue: AssignmentPriority {
        get { AssignmentPriority(rawValue: priority) ?? .normal }
        set { priority = newValue.rawValue }
    }

    var statusValue: AssignmentStatus {
        get { AssignmentStatus(rawValue: status) ?? .active }
        set { status = newValue.rawValue }
    }
}

/// How urgent the student says this is.
///
/// Three values, not a slider. A 1-10 scale invites marking everything an 8,
/// and a scheduler cannot act on a distinction the student did not really make.
enum AssignmentPriority: String, CaseIterable, Codable, Sendable, Identifiable {
    case low, normal, high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: "Low"
        case .normal: "Normal"
        case .high: "High"
        }
    }

    /// Higher sorts earlier. Only ever breaks a tie between two pieces of work
    /// competing for the same window — never overrides a deadline.
    var weight: Int {
        switch self {
        case .high: 2
        case .normal: 1
        case .low: 0
        }
    }
}

/// The assignment lifecycle, in the vocabulary the database actually accepts.
///
/// This was a loose string, and the client wrote `"done"` where the server's
/// check constraint allows only `active`/`completed`/`archived`. Nothing broke
/// yet because status is not synced — which is exactly the kind of bug that
/// waits for the feature that would have shipped it.
enum AssignmentStatus: String, CaseIterable, Codable, Sendable {
    case active, completed, archived
}

@Model
final class Subtask {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var title: String
    var guidance: String?
    var ordinal: Int
    var estimatedMinutes: Int
    var completedAt: Date?
    /// The rubric criterion this step serves, e.g. "A". Nil for general work.
    var criterionCode: String?
    /// What this step needs doing to it — `source_research`, `worked_examples`.
    /// Written by the planner, which knows why it wrote the step; the tool
    /// selector reads it instead of guessing from the title.
    ///
    /// Stored raw so an unknown value from a newer server is ignored rather
    /// than crashing an older client, and defaulted in the declaration because
    /// SwiftData needs a value for rows written before this column existed.
    var toolNeed: String? = nil

    var assignment: Assignment?

    @Relationship(deleteRule: .cascade, inverse: \PlanSessionRecord.subtask)
    var sessions: [PlanSessionRecord] = []

    init(id: UUID = UUID(), remoteID: UUID? = nil, title: String, guidance: String? = nil,
         ordinal: Int, estimatedMinutes: Int, criterionCode: String? = nil,
         toolNeed: String? = nil, assignment: Assignment? = nil) {
        self.id = id
        self.remoteID = remoteID
        self.title = title
        self.guidance = guidance
        self.ordinal = ordinal
        self.estimatedMinutes = estimatedMinutes
        self.criterionCode = criterionCode
        self.toolNeed = toolNeed
        self.assignment = assignment
    }

    /// The planner's recorded need, if it is one this build understands.
    var need: StudyTool.Need? { toolNeed.flatMap(StudyTool.Need.init(rawValue:)) }
}

@Model
final class PlanSessionRecord {
    #Index<PlanSessionRecord>([\.startsAt])
    @Attribute(.unique) var id: UUID
    var startsAt: Date
    var endsAt: Date
    var state: String
    /// Classes and other commitments the student did not choose. The scheduler
    /// routes around these and never through them.
    var isFixed: Bool

    // ── What actually happened ────────────────────────────────────────────
    // `startsAt`/`endsAt` are the *plan*. These three are the *record*, and
    // they are what the estimator learns from. Keeping them separate is what
    // stops "I marked it done" being mistaken for "I did it".
    //
    // All optional so an existing store migrates without losing anything.

    /// When a focus session was actually begun.
    var startedAt: Date?
    /// When it actually ended — by running out, or by being ended early.
    var endedAt: Date?
    /// Seconds genuinely spent in a running focus session, accumulated across
    /// pauses. Measured with a monotonic clock, so moving the device clock
    /// forward does not manufacture focus time.
    var focusedSeconds: Int?
    /// How many times the app was backgrounded mid-session. Not a punishment —
    /// it is the honest caveat on a session's duration.
    var interruptions: Int?

    var subtask: Subtask?

    init(id: UUID = UUID(), startsAt: Date, endsAt: Date,
         state: SessionState = .scheduled, isFixed: Bool = false,
         subtask: Subtask? = nil) {
        self.id = id
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.state = state.rawValue
        self.isFixed = isFixed
        self.subtask = subtask
    }

    /// How long the session was planned to run.
    var plannedSeconds: Int {
        max(0, Int(endsAt.timeIntervalSince(startsAt)))
    }

    /// Measured focus, in whole minutes. Nil when the session was never run —
    /// which is different from zero, and must stay different: an unrun session
    /// has no measurement, and guessing one would poison the estimator.
    var measuredMinutes: Int? {
        guard let focusedSeconds, focusedSeconds > 0 else { return nil }
        return max(1, focusedSeconds / 60)
    }

    var sessionState: SessionState {
        get { SessionState(rawValue: state) ?? .scheduled }
        set { state = newValue.rawValue }
    }
}

@Model
final class CompletionRecord {
    @Attribute(.unique) var id: UUID
    /// Mirrors the /logs payload exactly. Carries **no free text** — task type
    /// and durations only, never what the student was working on.
    var subjectCode: String?
    var taskType: String
    var estimatedMinutes: Int
    var actualMinutes: Int
    var hourBucket: Int?
    var minutesLate: Int?
    var highConfidence: Bool
    var completed: Bool
    var createdAt: Date
    /// False until the aggregate has been accepted by the server. Ingest is
    /// fire-and-forget, so this is what makes a retry possible.
    var synced: Bool

    init(id: UUID = UUID(), subjectCode: String?, taskType: String,
         estimatedMinutes: Int, actualMinutes: Int, hourBucket: Int? = nil,
         minutesLate: Int? = nil, highConfidence: Bool = false,
         completed: Bool = true, createdAt: Date = .now, synced: Bool = false) {
        self.id = id
        self.subjectCode = subjectCode
        self.taskType = taskType
        self.estimatedMinutes = estimatedMinutes
        self.actualMinutes = actualMinutes
        self.hourBucket = hourBucket
        self.minutesLate = minutesLate
        self.highConfidence = highConfidence
        self.completed = completed
        self.createdAt = createdAt
        self.synced = synced
    }
}

// MARK: - Rubrics

/// A rubric the student owns, saves once and reuses.
///
/// Two ways in, because both are real. Most students have a rubric as a block of
/// text on the assignment sheet — that is `body`, and it is enough to grade
/// against. Some want it broken into criteria they can see marks against — those
/// are `items`. Grading prefers items and falls back to the body, so pasting
/// works immediately and structure is an upgrade rather than a requirement.
@Model
final class Rubric {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var name: String
    /// `custom` when pasted, `template` when copied from curriculum data.
    var source: String
    var assessmentTypeID: UUID?
    /// The pasted sheet. Capped at the same 8000 characters the server enforces,
    /// so a rubric that saves locally is one the server will also accept.
    var body: String?
    var totalMarks: Int?
    var createdAt: Date
    var updatedAt: Date

    @Relationship(deleteRule: .cascade, inverse: \RubricItem.rubric)
    var items: [RubricItem] = []

    /// Assignments pointing here. Nullify rather than cascade: deleting a rubric
    /// must never delete the student's work, only the link to it.
    @Relationship(deleteRule: .nullify, inverse: \Assignment.rubric)
    var assignments: [Assignment] = []

    static let maxBodyCharacters = 8000
    static let maxItems = 40

    init(id: UUID = UUID(), remoteID: UUID? = nil, name: String,
         source: RubricSource = .custom, assessmentTypeID: UUID? = nil,
         body: String? = nil, totalMarks: Int? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.name = name
        self.source = source.rawValue
        self.assessmentTypeID = assessmentTypeID
        self.body = body
        self.totalMarks = totalMarks
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    var sortedItems: [RubricItem] {
        items.sorted { $0.ordinal < $1.ordinal }
    }

    /// Marks the student can actually be scored out of: the declared total when
    /// there is one, otherwise the sum of the criteria.
    var effectiveTotalMarks: Int? {
        if let totalMarks { return totalMarks }
        let summed = items.compactMap(\.marks).reduce(0, +)
        return summed > 0 ? summed : nil
    }

    /// A rubric with neither criteria nor text cannot ground anything, and
    /// grading against it would be a confident guess. The UI refuses to save one.
    var isUsable: Bool {
        !items.isEmpty || !(body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var summary: String {
        if !items.isEmpty {
            let marks = effectiveTotalMarks.map { " · \($0) marks" } ?? ""
            return "\(items.count) criteria\(marks)"
        }
        return "Pasted rubric"
    }
}

enum RubricSource: String, CaseIterable, Codable, Sendable {
    /// Pasted or typed by the student.
    case custom
    /// Copied out of curriculum reference data and then owned by the student.
    case template
}

@Model
final class RubricItem {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    /// The criterion letter or number, e.g. "A". Nil when the rubric does not
    /// use codes.
    var code: String?
    var name: String
    var marks: Int?
    var guidance: String?
    var ordinal: Int

    var rubric: Rubric?

    init(id: UUID = UUID(), remoteID: UUID? = nil, code: String? = nil,
         name: String, marks: Int? = nil, guidance: String? = nil,
         ordinal: Int, rubric: Rubric? = nil) {
        self.id = id
        self.remoteID = remoteID
        self.code = code
        self.name = name
        self.marks = marks
        self.guidance = guidance
        self.ordinal = ordinal
        self.rubric = rubric
    }

    /// "A · Knowledge" or just "Knowledge".
    var displayName: String {
        guard let code, !code.isEmpty else { return name }
        return "\(code) · \(name)"
    }
}

/// Everything the add screen collects, in one value.
///
/// A struct rather than eight positional arguments: the flow gained a rubric,
/// instructions, a priority and a course in one pass, and a call site with eight
/// unlabelled parameters is where the deadline and the estimate quietly swap.
@MainActor
struct NewAssignment {
    var title: String
    var taskType: String
    var deadline: Date
    var estimatedMinutes: Int
    var priority: AssignmentPriority = .normal
    var course: Course?
    var rubric: Rubric?
    /// What the student typed about the assignment. Capped at what the server
    /// accepts, so a note that saves is a note that syncs.
    var notes: String?

    /// Mirrors the breakdown endpoint and `assignments.title` constraint. Keep
    /// this beside the notes limit so every task-entry surface uses one client
    /// boundary rather than learning about a 422 after a network round trip.
    static let maxTitleCharacters = 200
    static let maxNoteCharacters = 2000
}

// MARK: - Grading

/// A marked piece of work.
///
/// **The work itself is not here, and never reaches this table on the server.**
/// Albus sends the text, gets marks and feedback back, and keeps only those plus
/// a character count. Nothing is lost that a student wants back — they have
/// their own essay — and the app stops being a repository of other people's
/// coursework, which is a category of thing worth not being.
@Model
final class Grading {
    @Attribute(.unique) var id: UUID
    var remoteID: UUID?
    var model: String
    /// How long the submission was. Enough to say "3,240 words marked" and to
    /// reason about cost; it reveals nothing about what was written.
    var inputChars: Int
    var overallMarks: Int?
    var totalMarks: Int?
    /// **The grade.** What the student's course would actually put on this work
    /// — "4", "B+", "62%" — in the scale they said their course uses.
    ///
    /// Not the same thing as `overallMarks`, and conflating the two is why this
    /// was missing: a four-strand MYP rubric totals 32, and 0/32 is arithmetic,
    /// not a grade. Nil for a blind reading, always, and enforced server-side
    /// rather than trusted here.
    var gradeLabel: String?
    /// One line on how that grade was reached. Nil whenever `gradeLabel` is.
    var gradeNote: String?
    /// What was marked, for a history list to be readable.
    ///
    /// The work itself is deliberately never stored, so without this a list of
    /// past gradings is a column of identical dates.
    var workTitle: String?
    /// Per-criterion marks and comments, in rubric order.
    var criteria: [GradedCriterion]
    var feedback: String
    /// What to change, in the order worth doing it. At most three.
    var improvements: [GradedImprovement] = []
    /// What this was marked against.
    ///
    /// **Stored, never inferred.** A blind reading and a rubric grading that
    /// awarded no marks look identical — both carry nil marks — so without this
    /// a saved blind reading could be reopened months later and read as though
    /// it had been marked against real criteria.
    var basisValue: String = GradingBasis.personal.rawValue
    var createdAt: Date

    var basis: GradingBasis {
        get { GradingBasis(rawValue: basisValue) ?? .personal }
        set { basisValue = newValue.rawValue }
    }

    var assignment: Assignment?

    init(id: UUID = UUID(), remoteID: UUID? = nil, model: String, inputChars: Int,
         overallMarks: Int? = nil, totalMarks: Int? = nil,
         gradeLabel: String? = nil, gradeNote: String? = nil,
         workTitle: String? = nil,
         criteria: [GradedCriterion] = [], feedback: String,
         improvements: [GradedImprovement] = [],
         basis: GradingBasis = .personal,
         assignment: Assignment? = nil, createdAt: Date = .now) {
        self.id = id
        self.remoteID = remoteID
        self.model = model
        self.inputChars = inputChars
        self.overallMarks = overallMarks
        self.totalMarks = totalMarks
        self.gradeLabel = gradeLabel
        self.gradeNote = gradeNote
        self.workTitle = workTitle
        self.criteria = criteria
        self.feedback = feedback
        self.improvements = improvements
        self.basisValue = basis.rawValue
        self.assignment = assignment
        self.createdAt = createdAt
    }

    /// "14/20". Nil when the rubric carried no marks, which is a real case and
    /// must not render as "0".
    var scoreText: String? {
        guard let overallMarks, let totalMarks, totalMarks > 0 else { return nil }
        return "\(overallMarks)/\(totalMarks)"
    }

    var fraction: Double? {
        guard let overallMarks, let totalMarks, totalMarks > 0 else { return nil }
        return min(1, Double(overallMarks) / Double(totalMarks))
    }

    /// Roughly, for display. Words are a unit students think in; characters
    /// are not.
    var approximateWords: Int { max(1, inputChars / 6) }

    /// What to call this in a list. Never empty, because a row with no label is
    /// a row nobody can pick out of five.
    var displayTitle: String {
        if let workTitle, !workTitle.isEmpty { return workTitle }
        if let title = assignment?.title, !title.isEmpty { return title }
        return basis == .blind ? "A reading" : "Marked work"
    }

    /// The one line that goes at the top: the grade if there is one, the marks
    /// if there are only marks, and nothing at all for a blind reading — where
    /// any headline would be read as a grade whatever sits beside it.
    var headline: String? {
        guard basis.isRubricBacked else { return nil }
        if let gradeLabel, !gradeLabel.isEmpty { return gradeLabel }
        return scoreText
    }

    /// True when the headline is a grade in the student's own scale rather than
    /// the rubric's raw arithmetic. Only the first deserves to be called one.
    var headlineIsGrade: Bool {
        guard let gradeLabel, !gradeLabel.isEmpty else { return false }
        return gradeLabel != scoreText
    }
}

/// One criterion's result. `Codable` because SwiftData stores it inline on the
/// grading rather than as a second table — these are never queried on their own.
/// What a grading was based on.
///
/// `blind` is the one that matters: no rubric was found, no marks were awarded,
/// and the result is a reading rather than a grade. Every screen that shows a
/// grading has to be able to tell, which is why this is persisted rather than
/// guessed from whether marks came back.
enum GradingBasis: String, Codable, Sendable {
    /// The student's own saved rubric — what a teacher actually handed out.
    case personal
    /// Albus's verified copy of how this curriculum component is marked.
    case curriculum
    /// No rubric. Not a grade.
    case blind

    var isRubricBacked: Bool { self != .blind }
}

/// One thing to change, and why it is worth doing.
struct GradedImprovement: Codable, Hashable, Sendable, Identifiable {
    var id: String { change }
    var change: String
    var why: String
}

struct GradedCriterion: Codable, Hashable, Sendable, Identifiable {
    var id: String { (code ?? "") + name }
    var code: String?
    var name: String
    var marks: Int?
    var outOf: Int?
    var comment: String
    /// A sentence lifted from the student's own work, or nil.
    ///
    /// The thing that makes a mark land. A criticism next to the sentence it is
    /// about reads as marking; the same criticism on its own reads as invented.
    var quote: String?
    /// Where that sentence is — "¶4 · line 6". Display only, never parsed.
    var whereFound: String?

    var displayName: String {
        guard let code, !code.isEmpty else { return name }
        return "\(code) · \(name)"
    }

    var scoreText: String? {
        guard let marks, let outOf, outOf > 0 else { return nil }
        return "\(marks)/\(outOf)"
    }
}
