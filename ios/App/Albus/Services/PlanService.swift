import Foundation
import Supabase
import AlbusCore

/// Asks the backend to turn an assignment into startable steps.
///
/// The server owns generation because it holds the Anthropic key and enforces
/// the quota; both would be trivially bypassed on device. This type is only
/// the transport — it does not decide what a plan should look like.
struct PlanService {

    struct Step: Decodable, Sendable {
        let title: String
        let guidance: String
        let estimatedMinutes: Int
        let criterionCode: String?
        /// What this step needs doing to it. Decides which tools the step row
        /// offers, out of the whole catalogue rather than a hard-coded few.
        let toolNeed: String?

        private enum CodingKeys: String, CodingKey {
            case title, guidance
            case estimatedMinutes = "estimated_minutes"
            case criterionCode = "rubric_criterion_code"
            case toolNeed = "tool_need"
        }
    }

    struct Result: Decodable, Sendable {
        let assignmentID: UUID
        let model: String
        let rubricGrounded: Bool
        /// "personal", "curriculum", or nil when the plan was generic. Lets the
        /// UI tell the student *which* rubric shaped their plan.
        let rubricSource: String?
        let steps: [Step]

        private enum CodingKeys: String, CodingKey {
            case assignmentID = "assignment_id"
            case model
            case rubricGrounded = "rubric_grounded"
            case rubricSource = "rubric_source"
            case steps
        }
    }

    /// Maps the server's error codes onto something a screen can act on.
    /// Kept as cases rather than strings so a new server error cannot be
    /// silently rendered as raw text to a student.
    enum Failure: LocalizedError, Equatable {
        case quotaReached
        /// This week's AI plans are spent. The server answers 402 exactly as it
        /// does for the open-task cap, so the code must be read before the
        /// status or a student out of AI plans is told they have too many tasks.
        case aiPlansUsed
        /// The student's plan includes no AI plans at all.
        case aiPlansNotIncluded
        case rateLimited
        case fairUseReached
        case offline
        case unusableResponse
        case unavailable
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .quotaReached:
                // No number: Free keeps 5 open, Plus 10, Pro as many as the
                // student is actually carrying. A literal here would be wrong
                // for two of the three, and the one it was wrong for would
                // never see it — which is how it stayed wrong.
                "That's as many tasks as your plan keeps open at once. "
                + "Finish one, or move up a plan."
            case .aiPlansUsed:
                "You've used this week's AI plans."
            case .aiPlansNotIncluded:
                "AI plans aren't included in your plan."
            case .rateLimited:
                "That's a lot of planning at once. Try again shortly."
            case .fairUseReached:
                "This account has reached its monthly AI safety limit. "
                + "Existing tasks still work, and capacity returns gradually over 30 days."
            case .offline:
                "No connection."
            case .unusableResponse:
                ModelResponseFailure.retryableDescription
            case .unavailable:
                "Albus can't plan right now. Your assignment is saved."
            case .rejected(let why):
                why
            }
        }

        /// Whether Albus should plan this on the phone instead.
        ///
        /// Every refusal that is about the AI rather than the assignment. Not
        /// the open-task cap — planning locally past it would make the cap
        /// meaningless — and not a rejected request, which needs correcting.
        var plansLocally: Bool {
            switch self {
            case .quotaReached, .rejected: false
            case .aiPlansUsed, .aiPlansNotIncluded, .rateLimited, .fairUseReached,
                 .offline, .unusableResponse, .unavailable: true
            }
        }

        /// What the student is told when the phone made the plan.
        var localPlanNote: String {
            switch self {
            case .aiPlansUsed:
                "You've used this week's AI plans, so Albus split this into study "
                + "sessions for you. Plus writes a step-by-step plan every time."
            case .aiPlansNotIncluded:
                "Albus split this into study sessions for you. "
                + "Plus writes a step-by-step plan every time."
            case .offline:
                "No connection, so Albus split this into study sessions for you."
            default:
                "Albus couldn't write a step-by-step plan right now, "
                + "so it split this into study sessions for you."
            }
        }

        /// True when the honest next step is a plan with more AI in it.
        var suggestsUpgrade: Bool { self == .aiPlansUsed || self == .aiPlansNotIncluded }
    }

    private struct Request: Encodable {
        let title: String
        let task_type: String
        let deadline: String
        let estimated_minutes: Int
        /// The student's own subject, by server id. The server checks it belongs
        /// to the caller before attaching the assignment to it.
        let course_id: String?
        /// What the student typed about the assignment. Reaches the model
        /// fenced as data; the server caps it at 2000 characters.
        let notes: String?
        /// The student's own rubric, by id. The rubric itself is never sent —
        /// the server loads it through the caller's own RLS context, so a
        /// forged id resolves to nothing rather than to someone else's rubric.
        let rubric_id: String?
        let priority: String
        /// What the student can study in a day. Sets how long one step may be,
        /// and so how many steps the work divides into.
        let daily_capacity_minutes: Int
    }

    private struct ErrorBody: Decodable { let error: String?; let message: String? }

    private let client: SupabaseClient?

    init(client: SupabaseClient? = Backend.shared) {
        self.client = client
    }

    func breakdown(title: String, taskType: String, deadline: Date,
                   estimatedMinutes: Int,
                   courseID: UUID? = nil, notes: String? = nil,
                   rubricID: UUID? = nil,
                   priority: AssignmentPriority = .normal,
                   dailyCapacityMinutes: Int = 150) async throws -> Result {
        let trimmedNotes = notes?.trimmingCharacters(in: .whitespacesAndNewlines)

        let body = Request(
            title: title,
            task_type: taskType,
            deadline: ISO8601DateFormatter().string(from: deadline),
            estimated_minutes: estimatedMinutes,
            course_id: courseID?.uuidString,
            notes: (trimmedNotes?.isEmpty ?? true) ? nil : trimmedNotes,
            rubric_id: rubricID?.uuidString,
            priority: priority.rawValue,
            daily_capacity_minutes: dailyCapacityMinutes
        )

        guard let client else { throw Failure.unavailable }

        do {
            return try await client.functions.invoke(
                "breakdown", options: .init(headers: await DeviceSignal.headers(), body: body))
        } catch let error as FunctionsError {
            throw Self.translate(error)
        } catch let error as URLError {
            throw error.code == .notConnectedToInternet || error.code == .networkConnectionLost
                ? Failure.offline
                : Failure.unavailable
        }
    }

    /// The server returns a machine-readable code; surface the ones a student
    /// can act on and collapse the rest into "unavailable". Leaking internal
    /// error text to a UI is how implementation details end up on screen.
    static func translate(_ error: FunctionsError) -> Failure {
        guard case .httpError(let code, let data) = error else { return .unavailable }

        let body = try? JSONDecoder().decode(ErrorBody.self, from: data)
        switch body?.error {
        // Both names: `FREE_PLAN_LIMIT_REACHED` is what migration 0034 retired,
        // and an app in someone's hand is always older than the server it talks to.
        case "PLAN_TASK_LIMIT_REACHED", "FREE_PLAN_LIMIT_REACHED":
            return .quotaReached
        case "ALLOWANCE_WEEKLY":                        return .aiPlansUsed
        case "PLAN_UPGRADE_REQUIRED":                   return .aiPlansNotIncluded
        case "RATE_LIMIT_HOURLY", "RATE_LIMIT_DAILY":   return .rateLimited
        case "FAIR_USE_REACHED":                        return .fairUseReached
        case "GLOBAL_CAPACITY_REACHED":                 return .unavailable
        case "EMPTY_RESPONSE", "MALFORMED_RESPONSE":    return .unusableResponse
        default: break
        }

        switch code {
        case 402:        return .quotaReached
        case 429:        return .rateLimited
        case 422, 413:   return .rejected(body?.message ?? "Albus couldn't plan that.")
        default:         return .unavailable
        }
    }
}
