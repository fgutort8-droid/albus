import Foundation
import Supabase

/// Sends finished work to be marked against the student's own rubric.
///
/// Transport only. The paywall, the rate limit and the size cap are all
/// server-side — this type cannot enforce any of them and does not pretend to.
/// What it *does* own is telling the student the truth about what came back,
/// which is why `Failure` is a closed set of cases rather than a string: a new
/// server error must never render to a student as raw text.
struct GradingService {

    struct Criterion: Decodable, Sendable {
        let code: String?
        let name: String
        let marks: Int?
        let outOf: Int?
        let comment: String
        let quote: String?
        let whereFound: String?

        private enum CodingKeys: String, CodingKey {
            case code, name, marks, comment, quote
            case outOf = "out_of"
            case whereFound = "where"
        }
    }

    struct Improvement: Decodable, Sendable {
        let change: String
        let why: String
    }

    struct Result: Decodable, Sendable {
        let id: UUID
        let overallMarks: Int?
        let totalMarks: Int?
        /// The grade, in the scale the student said their course uses.
        ///
        /// Distinct from `overallMarks` on purpose: a four-strand MYP rubric
        /// totals 32, and 0/32 is arithmetic rather than a grade. Guaranteed
        /// nil for a blind reading — the server strips it after the model has
        /// spoken, so a label cannot arrive on a reading that is not a grade.
        let gradeLabel: String?
        let gradeNote: String?
        /// What was marked, echoed back so history rows have a name.
        let title: String?
        let criteria: [Criterion]
        let feedback: String
        let improvements: [Improvement]
        let model: String
        /// What the marks were based on, decided server-side.
        ///
        /// Never inferred from whether marks came back: a curriculum rubric
        /// carrying no marks and a blind reading both arrive as nils, and only
        /// one of them may be shown as a grade.
        let basis: GradingBasis
        /// The rubric's name, for "marking against …". Nil when blind.
        let rubricName: String?
        /// True when the server returned an identical earlier grading instead
        /// of paying to produce the same one again.
        let reused: Bool

        private enum CodingKeys: String, CodingKey {
            case id, criteria, feedback, improvements, model, basis, reused, title
            case overallMarks = "overall_marks"
            case totalMarks = "total_marks"
            case gradeLabel = "grade_label"
            case gradeNote = "grade_note"
            case rubricName = "rubric_name"
        }
    }

    enum Failure: LocalizedError, Equatable {
        /// This plan does not include marking. The answer is a price list.
        ///
        /// Distinct from `allowanceUsed` on purpose, and the distinction is the
        /// whole point of having two cases. "Upgrade to get this" and "you'll
        /// have another on Tuesday" are different sentences shown to different
        /// people, and a single case would have to guess which — reliably
        /// showing a paying student a paywall for something they already bought.
        case notOnPlan
        /// The plan covers marking and this period's allowance is spent.
        /// Carries when the next one arrives, because that is the only part a
        /// student can act on.
        case allowanceUsed(resetsAt: Date?)
        /// Too many, too fast. Comes back in minutes and has nothing to do with
        /// which plan they are on — telling them to upgrade here would be
        /// selling them something that would not have helped.
        case tooFast
        /// Risk asked for a real sign-in before spending more.
        case needsVerification
        /// Risk paused AI features on this account. Recovers on its own.
        case paused
        /// A server-owned rolling cost ceiling. This is deliberately not a
        /// paywall: buying the plan again would not remove an abuse safeguard.
        case fairUseReached
        case tooLong(Int)
        /// Accepted, marked, and the answer ran past what the model could
        /// write in one go. Not the same as `tooLong`, which is refused before
        /// anything is spent.
        case tooLongToMark
        case tooShort
        case noRubric
        case offline
        case unusableResponse
        case unavailable
        case rejected(String)
        /// The work was sent and the answer never came back: the connection
        /// dropped or timed out mid-marking. The server may well have finished
        /// and saved it, so `MarkingCoordinator` looks it up with
        /// `recover(since:)` rather than reporting a failure. Never shown.
        case answerLost

        var errorDescription: String? {
            switch self {
            case .answerLost:
                Failure.unavailable.errorDescription
            case .notOnPlan:
                "Marking is part of Albus Plus and Pro."
            case .allowanceUsed(let resetsAt):
                if let resetsAt {
                    "That's this week's markings used. You'll have another \(Self.when(resetsAt))."
                } else {
                    "That's this week's markings used."
                }
            case .tooFast:
                "That's a lot of marking at once. Try again in a few minutes."
            case .needsVerification:
                "Sign in to carry on marking. It takes a moment and it's a one-off."
            case .paused:
                "Albus has paused marking on this account. It comes back on its own."
            case .fairUseReached:
                "This account has reached its monthly AI safety limit. "
                + "Capacity returns gradually over 30 days."
            case .tooLong(let max):
                "That's longer than Albus can mark in one go (about \(max / 6) words)."
            case .tooLongToMark:
                "There was too much to say about that in one go. Try marking a "
                + "section of it, or a rubric with fewer criteria."
            case .tooShort:
                "There isn't enough here to mark yet."
            case .noRubric:
                "Pick a rubric to mark this against."
            case .offline:
                "No connection — marking needs one."
            case .unusableResponse:
                ModelResponseFailure.retryableDescription
            case .unavailable:
                // Never "nothing was charged" — the client cannot know that. A
                // grading is reserved before the model runs, so a failure here
                // may or may not have cost one, and claiming otherwise was a
                // lie a student could check. The server hands the slot back on
                // failure and returns an identical result for free on a retry,
                // which is what makes this true rather than reassuring.
                "Albus couldn't finish marking that. Try again — you won't be charged twice."
            case .rejected(let why):
                why
            }
        }

        /// Whether the way out of this is a different plan. Drives whether the
        /// screen offers a price list or a date, and nothing else decides it.
        var isAnswerableByUpgrading: Bool {
            switch self {
            case .notOnPlan: true
            case .allowanceUsed: true
            default: false
            }
        }

        /// "on Tuesday" / "in 3 hours" / "shortly".
        private static func when(_ date: Date) -> String {
            let seconds = date.timeIntervalSinceNow
            guard seconds > 0 else { return "shortly" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            return formatter.localizedString(for: date, relativeTo: .now)
        }
    }

    /// Mirrors MAX_WORK_CHARS in the edge function. Used for a local warning
    /// only — the server rejects rather than truncates, so this being out of
    /// step costs a worse message, never a wrong grade.
    static let maxWorkCharacters = 20_000
    static let minWorkCharacters = 200

    private struct Request: Encodable {
        let assignment_id: String?
        /// Optional now, and only an override — the server works the rubric out
        /// from the assignment when this is absent.
        let rubric_id: String?
        let work: String
        /// How the student asked for the result to be shown, in their words.
        let presentation: String?
        /// What the student calls this piece — a filename, "Photo of your
        /// work", the assignment's own title. Only ever labels their own
        /// history row; the server fences it before it reaches the model.
        let title: String?
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    /// Marks a piece of work.
    ///
    /// Both ids are optional and the pair decides what happens. An assignment
    /// lets the server find the right mark scheme by itself; an explicit rubric
    /// overrides that; neither means a blind reading, which is a supported
    /// outcome rather than a failure.
    func grade(work: String, rubricID: UUID?, assignmentID: UUID?,
               presentation: String?, title: String? = nil) async throws -> Result {
        guard let client else { throw Failure.unavailable }

        let trimmed = work.trimmingCharacters(in: .whitespacesAndNewlines)
        // Checked here as well as on the server, so an obviously-too-short
        // submission does not cost a round trip to be told so.
        guard trimmed.count >= Self.minWorkCharacters else { throw Failure.tooShort }
        guard trimmed.count <= Self.maxWorkCharacters else {
            throw Failure.tooLong(Self.maxWorkCharacters)
        }

        let body = Request(assignment_id: assignmentID?.uuidString,
                           rubric_id: rubricID?.uuidString,
                           work: trimmed,
                           presentation: presentation?
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                               .nilIfEmpty,
                           title: title?
                               .trimmingCharacters(in: .whitespacesAndNewlines)
                               .nilIfEmpty)

        do {
            // Marking a full essay on Opus legitimately runs past thirty
            // seconds, which is long enough for the default request timeout to
            // give up on a request the server is still happily working on. The
            // student then sees a failure for work that was in fact marked, and
            // has spent a grading to see it.
            return try await client.functions.invoke(
                "grade", options: .init(headers: await DeviceSignal.headers(), body: body))
        } catch let error as FunctionsError {
            throw Self.translate(error)
        } catch let error as URLError {
            switch error.code {
            // Never left the phone: nothing was marked, and saying so is honest.
            case .notConnectedToInternet:
                throw Failure.offline
            // Left the phone, and the answer did not come back. The marking
            // may have finished on the server anyway; see `answerLost`.
            case .networkConnectionLost, .timedOut:
                throw Failure.answerLost
            default:
                throw Failure.unavailable
            }
        }
    }

    /// The newest grading the server saved at or after `since`, for a marking
    /// whose answer never reached the phone.
    ///
    /// The server stores every grading it produces before answering, and row
    /// security limits this to the caller's own. Reading it back costs nothing
    /// and marks nothing, unlike sending the work again, which could start a
    /// second, paid marking while the first is still running.
    func recover(since: Date) async throws -> Result? {
        guard let client else { throw Failure.unavailable }
        let rows: [SavedGrading] = try await client.from("gradings")
            // One literal, as in `grade/index.ts`: these are the columns its
            // own reuse path returns, in the shape the app already reads.
            .select("id, overall_marks, total_marks, grade_label, grade_note, work_title, breakdown, feedback, improvements, model, basis")
            .gte("created_at", value: ISO8601DateFormatter().string(from: since))
            .order("created_at", ascending: false)
            .limit(1)
            .execute()
            .value
        return rows.first?.result
    }

    /// A row of `gradings`: what `grade` returned, as the server keeps it.
    private struct SavedGrading: Decodable {
        let id: UUID
        let overallMarks: Int?
        let totalMarks: Int?
        let gradeLabel: String?
        let gradeNote: String?
        let workTitle: String?
        let breakdown: [Criterion]
        let feedback: String
        let improvements: [Improvement]
        let model: String
        let basis: GradingBasis

        private enum CodingKeys: String, CodingKey {
            case id, breakdown, feedback, improvements, model, basis
            case overallMarks = "overall_marks"
            case totalMarks = "total_marks"
            case gradeLabel = "grade_label"
            case gradeNote = "grade_note"
            case workTitle = "work_title"
        }

        var result: Result {
            Result(id: id, overallMarks: overallMarks, totalMarks: totalMarks,
                   gradeLabel: gradeLabel, gradeNote: gradeNote, title: workTitle,
                   criteria: breakdown, feedback: feedback, improvements: improvements,
                   model: model, basis: basis, rubricName: nil, reused: true)
        }
    }

    static func translate(_ error: FunctionsError) -> Failure {
        guard case .httpError(let code, let data) = error else { return .unavailable }

        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch body?.error {
        // `PLUS_REQUIRED` and `RUBRIC_REQUIRED` were removed rather than kept
        // "just in case": no database function can raise the first any more
        // (checked against pg_proc, not assumed), and the endpoint no longer
        // rejects a missing rubric — it grades blind instead. A branch that
        // cannot be reached is a branch nobody will maintain correctly.
        case "PLAN_UPGRADE_REQUIRED":   return .notOnPlan
        // `RATE_LIMIT_WEEKLY` is the name migration 0034 retired. Still mapped:
        // an app in someone's hand is older than the server it talks to, always.
        case "ALLOWANCE_WEEKLY", "RATE_LIMIT_WEEKLY":
            return .allowanceUsed(resetsAt: nil)
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY":   return .tooFast
        case "VERIFICATION_REQUIRED":   return .needsVerification
        case "ABUSE_SUSPECTED":         return .paused
        case "FAIR_USE_REACHED":        return .fairUseReached
        case "WORK_TOO_LONG":           return .tooLong(maxWorkCharacters)
        case "WORK_TOO_SHORT":          return .tooShort
        case "RUBRIC_NOT_FOUND":        return .noRubric
        case "GLOBAL_CAPACITY_REACHED": return .unavailable
        case "EMPTY_RESPONSE", "MALFORMED_RESPONSE":
            return .unusableResponse
        // Marking ran past the output cap. Distinct from an ordinary failure
        // because retrying identical work will truncate identically — the
        // student needs to know to send less, not to try again.
        case "RESPONSE_TRUNCATED":      return .tooLongToMark
        default: break
        }

        switch code {
        // An unrecognised 402 is *some* payment-shaped refusal, and the two it
        // could be want opposite sentences. Rather than guess — and eventually
        // tell a Plus subscriber to buy Plus — hand back what the server said.
        // It is the one party that knows.
        case 402, 403: return .rejected(body?.message ?? "Albus couldn't mark that.")
        case 429:      return .tooFast
        case 413:      return .tooLong(maxWorkCharacters)
        case 404, 422: return .rejected(body?.message ?? "Albus couldn't mark that.")
        default:       return .unavailable
        }
    }
}
