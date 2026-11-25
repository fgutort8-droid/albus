import Foundation
import Testing
@testable import Albus

@MainActor
@Suite("Entitlement refresh")
struct EntitlementServiceTests {

    private enum StubFailure: Error { case offline }

    private actor StubReader: PlanReading {
        enum Mode: Sendable {
            case fail
            case succeed(EntitlementService.Plan?)
        }

        private var mode: Mode

        init(_ mode: Mode) { self.mode = mode }

        func set(_ mode: Mode) { self.mode = mode }

        func fetch() async throws -> EntitlementService.Plan? {
            switch mode {
            case .fail: throw StubFailure.offline
            case .succeed(let plan): return plan
            }
        }
    }

    @Test("a failed refresh keeps the previous plan and exposes stale state")
    func failureIsVisibleWithoutDowngrading() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)

        await service.refresh()

        #expect(service.plan == .freeFallback)
        #expect(service.lastCheckedAt == nil)
        #expect(service.refreshFailed)
    }

    @Test("dismissal hides only the warning")
    func dismissalDoesNotChangeThePlan() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)
        await service.refresh()
        let plan = service.plan

        service.dismissRefreshFailure()

        #expect(!service.refreshFailed)
        #expect(service.plan == plan)
    }

    @Test("a later successful refresh clears stale state")
    func successClearsTheFailure() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)
        await service.refresh()
        await reader.set(.succeed(.freeFallback))

        await service.refresh()

        #expect(!service.refreshFailed)
        #expect(service.lastCheckedAt != nil)
    }

    @Test("a new rubric asks only once the plan has been read")
    func rubricLimitWaitsForThePlan() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)

        // The Free plan on screen before the first read is a placeholder,
        // not the student's: a Plus student must not be told Free's limit.
        #expect(service.rubricLimit(reachedBy: 3) == nil)
        await service.refresh()
        #expect(service.rubricLimit(reachedBy: 3) == nil)

        await reader.set(.succeed(.freeFallback))
        await service.refresh()
        #expect(service.rubricLimit(reachedBy: 2) == nil)
        #expect(service.rubricLimit(reachedBy: 3) == 3)
        #expect(service.rubricLimit(reachedBy: 4) == 3)
    }

    @Test("each plan asks at its own rubric limit, and Pro never does")
    func rubricLimitFollowsThePlan() async {
        let onPlus = EntitlementService(reader: StubReader(.succeed(.fixture(.plus))))
        await onPlus.refresh()
        #expect(onPlus.rubricLimit(reachedBy: 4) == nil)
        #expect(onPlus.rubricLimit(reachedBy: 5) == 5)

        let onPro = EntitlementService(reader: StubReader(.succeed(.fixture(.pro))))
        await onPro.refresh()
        #expect(onPro.rubricLimit(reachedBy: 500) == nil)
    }

    @Test("adding a task sends a full plan to the plans only once it has been read")
    func taskLimitWaitsForThePlan() async {
        let reader = StubReader(.fail)
        let service = EntitlementService(reader: reader)

        // Free's placeholder: a Plus student with six open is not full.
        #expect(service.taskLimit(reachedBy: 6) == nil)
        await service.refresh()
        #expect(service.taskLimit(reachedBy: 6) == nil)

        await reader.set(.succeed(.freeFallback))
        await service.refresh()
        #expect(service.taskLimit(reachedBy: 4) == nil)
        #expect(service.taskLimit(reachedBy: 5) == 5)
    }

    @Test("each plan fills at its own task limit, and Pro never does")
    func taskLimitFollowsThePlan() async {
        let onPlus = EntitlementService(reader: StubReader(.succeed(.fixture(.plus))))
        await onPlus.refresh()
        #expect(onPlus.taskLimit(reachedBy: 9) == nil)
        #expect(onPlus.taskLimit(reachedBy: 10) == 10)

        let onPro = EntitlementService(reader: StubReader(.succeed(.fixture(.pro))))
        await onPro.refresh()
        #expect(onPro.taskLimit(reachedBy: 500) == nil)
    }
}
