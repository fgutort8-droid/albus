import Foundation
import Supabase
import SwiftData
import Testing
import AlbusCore
@testable import Albus

/// What a student experiences at each limit. The server tests prove a limit is
/// enforced; these prove that hitting one leaves the student with a plan, a
/// clear sentence, and — when it is the honest answer — a way to upgrade.
@MainActor
@Suite("Tier limits in the app")
struct TierLimitTests {

    private func store() throws -> ModelContext {
        ModelContext(try ModelContainer(
            for: AlbusSchema.schema,
            configurations: ModelConfiguration(schema: AlbusSchema.schema, isStoredInMemoryOnly: true)))
    }

    private func refusal(_ code: String, status: Int = 402) -> FunctionsError {
        .httpError(code: status, data: try! JSONSerialization.data(withJSONObject: ["error": code]))
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let availability = Availability(windowStartHour: 0, windowEndHour: 24,
                                            dailyCapacityMinutes: 60)

    private func essay(minutes: Int = 240) -> NewAssignment {
        NewAssignment(title: "History essay", taskType: "essay",
                      deadline: now.addingTimeInterval(14 * 86_400),
                      estimatedMinutes: minutes)
    }

    // MARK: - Reading the server's answer

    // The bug this exists for: the server answers 402 both for "too many open
    // tasks" and for "this week's AI plans are used". Reading the status alone
    // told a student with three tasks that they had too many.
    @Test("used-up AI plans are not mistaken for the open-task cap")
    func aiPlansAreNotTheTaskCap() {
        #expect(PlanService.translate(refusal("ALLOWANCE_WEEKLY")) == .aiPlansUsed)
        #expect(PlanService.translate(refusal("PLAN_UPGRADE_REQUIRED")) == .aiPlansNotIncluded)
        #expect(PlanService.translate(refusal("PLAN_TASK_LIMIT_REACHED")) == .quotaReached)
    }

    @Test("every refusal about the AI is planned on the phone instead")
    func aiRefusalsPlanLocally() {
        let local: [PlanService.Failure] = [.aiPlansUsed, .aiPlansNotIncluded, .rateLimited,
                                            .fairUseReached, .offline, .unusableResponse,
                                            .unavailable]
        for failure in local {
            #expect(failure.plansLocally, "\(failure) should be planned on the phone")
        }
    }

    // Planning past the open-task cap on the phone would make the cap
    // meaningless, and a rejected request needs correcting, not a plan.
    @Test("the open-task cap and a rejected request are never planned around")
    func capIsNotPlannedAround() {
        #expect(!PlanService.Failure.quotaReached.plansLocally)
        #expect(!PlanService.Failure.rejected("Deadline is in the past.").plansLocally)
    }

    @Test("only running out of AI plans points at Plus")
    func upgradeOnlyWhenItIsTheAnswer() {
        #expect(PlanService.Failure.aiPlansUsed.suggestsUpgrade)
        #expect(PlanService.Failure.aiPlansNotIncluded.suggestsUpgrade)
        #expect(!PlanService.Failure.offline.suggestsUpgrade)
        #expect(!PlanService.Failure.unavailable.suggestsUpgrade)
    }

    // The old offline sentence promised "Albus will plan this when you're back
    // online". Nothing ever did. The note must describe what actually happened.
    @Test("the offline note promises nothing that does not happen")
    func offlineNoteIsTrue() {
        let note = PlanService.Failure.offline.localPlanNote
        #expect(!note.contains("back online"))
        #expect(note.contains("study sessions"))
    }

    // MARK: - What the coordinator does

    // A planner with no server connection fails as `.unavailable`, which is the
    // same path as used-up AI plans or no signal: the phone plans instead.
    @Test("when the AI cannot plan, the assignment still gets scheduled sessions")
    func unavailableAIStillProducesAPlan() async throws {
        let ctx = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil))

        await coordinator.addAssignment(essay(minutes: 240), context: ctx,
                                        availability: availability, now: now)

        let assignment = try #require(try ctx.fetch(FetchDescriptor<Assignment>()).first)
        #expect(assignment.subtasks.count == 4)
        #expect(assignment.subtasks.map(\.estimatedMinutes).reduce(0, +) == 240)
        #expect(assignment.subtasks.allSatisfy { $0.estimatedMinutes <= 60 })
        let onCalendar = try ctx.fetch(FetchDescriptor<PlanSessionRecord>())
        #expect(onCalendar.count == 4, "every phone-made session should be on the calendar")
        #expect(coordinator.status == .plannedLocally(
            note: PlanService.Failure.unavailable.localPlanNote, suggestsUpgrade: false))
    }

    @Test("at the open-task cap, nothing is created and nothing is sent")
    func capIsEnforcedOnTheDevice() async throws {
        let ctx = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil))
        for _ in 0..<5 {
            await coordinator.addAssignment(essay(minutes: 60), context: ctx,
                                            availability: availability, taskLimit: 5, now: now)
        }
        let beforeCap = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(beforeCap.count == 5)

        await coordinator.addAssignment(essay(minutes: 60), context: ctx,
                                        availability: availability, taskLimit: 5, now: now)

        let afterCap = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(afterCap.count == 5, "a sixth open assignment must not exist, even unplanned")
        #expect(coordinator.status == .failed(PlanService.Failure.quotaReached.errorDescription ?? ""))
    }

    @Test("finished work frees its place under the cap")
    func finishingFreesAPlace() async throws {
        let ctx = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil))
        for _ in 0..<5 {
            await coordinator.addAssignment(essay(minutes: 60), context: ctx,
                                            availability: availability, taskLimit: 5, now: now)
        }
        let done = try #require(try ctx.fetch(FetchDescriptor<Assignment>()).first)
        for step in done.subtasks { step.completedAt = now }

        await coordinator.addAssignment(essay(minutes: 60), context: ctx,
                                        availability: availability, taskLimit: 5, now: now)

        let afterFinishing = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(afterFinishing.count == 6)
    }

    @Test("a paid plan's unlimited tasks are never capped on the device")
    func unlimitedIsNotCapped() async throws {
        let ctx = try store()
        let coordinator = PlanCoordinator(plans: PlanService(client: nil))
        for _ in 0..<12 {
            await coordinator.addAssignment(essay(minutes: 60), context: ctx,
                                            availability: availability, taskLimit: nil, now: now)
        }
        let all = try ctx.fetch(FetchDescriptor<Assignment>())
        #expect(all.count == 12)
    }

    // MARK: - What the meter shows

    /// What `my_plan()` returns for a Free student, from either server.
    private func freeRow(withAIPlans: Bool) throws -> PlanReader.Row {
        var row: [String: Any] = [
            "tier": "free", "display_name": "Free", "price_cents": 0, "currency": "EUR",
            "expires_at": NSNull(),
            "active_tasks_limit": 5, "active_tasks_used": 1,
            "grade_limit_week": 0, "grade_used_week": 0, "grade_resets_at": NSNull(),
            "rubrics_limit": 3, "rubrics_used": 0,
            "tools_access": "basic", "curriculum_intelligence": false, "advanced_models": false,
        ]
        if withAIPlans {
            row["breakdown_limit_week"] = 3
            row["breakdown_used_week"] = 2
            row["breakdown_resets_at"] = NSNull()
        }
        return try JSONDecoder().decode(PlanReader.Row.self,
                                        from: JSONSerialization.data(withJSONObject: row))
    }

    @Test("the meter reads this week's AI plans from the server")
    func meterReadsTheAllowance() throws {
        let plan = PlanReader.plan(from: try freeRow(withAIPlans: true))
        #expect(plan.aiPlans?.limit == 3)
        #expect(plan.aiPlans?.remaining == 1)
    }

    // The app ships against whichever server is live. Before the allowance
    // migration is deployed, `my_plan()` sends no AI-plan fields at all; a
    // required field would fail the whole read and blank every meter.
    @Test("a server without the AI-plan allowance still yields a readable plan")
    func olderServerStillDecodes() throws {
        let plan = PlanReader.plan(from: try freeRow(withAIPlans: false))
        #expect(plan.tasks.limit == 5, "the rest of the plan must survive")
        // Not metered is not unlimited. Showing "Unlimited" on a Free account is
        // the exact false claim SettingsUITests guards against.
        #expect(plan.aiPlans == nil)
    }

    @Test("Free's offline fallback still knows it has three AI plans")
    func fallbackKnowsTheAllowance() {
        let fallback = EntitlementService.Plan.freeFallback
        #expect(fallback.aiPlans?.limit == 3)
        #expect(fallback.aiPlans?.hasAny == true)
    }
}
