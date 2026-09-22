import SwiftUI
import Testing
import UIKit
@testable import Albus

/// The paywall in the states a student can meet, drawn to PNG files for a
/// person to look at. No network: the store and the plan are stand-ins.
///
/// Off unless asked for, because a picture is not an assertion:
///
///     TEST_RUNNER_ALBUS_SNAPSHOT_DIR=/tmp/paywall xcodebuild test-without-building \
///       ... -only-testing:AlbusTests/PaywallSnapshots
@MainActor
@Suite("Paywall snapshots",
       .enabled(if: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"] != nil))
struct PaywallSnapshots {

    private actor FixedPlan: PlanReading {
        let plan: EntitlementService.Plan
        init(_ plan: EntitlementService.Plan) { self.plan = plan }
        func fetch() async throws -> EntitlementService.Plan? { plan }
    }

    private func entitlements(_ tier: EntitlementService.Tier) async -> EntitlementService {
        let free = EntitlementService.Plan.freeFallback
        let plan = EntitlementService.Plan(
            tier: tier, displayName: PurchaseFlow.name(tier), priceCents: 0, currency: "EUR",
            expiresAt: tier == .free ? nil : .now.addingTimeInterval(86_400 * 20),
            tasks: free.tasks, aiPlans: free.aiPlans, grader: free.grader, rubrics: free.rubrics,
            toolsAccess: free.toolsAccess, curriculumIntelligence: false, advancedModels: false)
        let service = EntitlementService(reader: FixedPlan(plan))
        await service.refresh()
        return service
    }

    private func store(trial: Bool) async -> PurchaseService {
        let fake = PurchaseServiceTests.FakeStore()
        fake.offersResult = .success(PurchaseServiceTests.catalogue.map {
            StoreOffer(productID: $0.productID, price: $0.price, amount: $0.amount,
                       pricePerWeek: $0.pricePerWeek, freeTrial: trial ? "3 days" : nil)
        })
        let service = PurchaseService(store: fake)
        await service.start(userID: UUID())
        return service
    }

    private func render(_ name: String, _ screen: PaywallScreen,
                        entitlements: EntitlementService, purchases: PurchaseService) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: screen
            .environment(entitlements)
            .environment(purchases))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Long enough for the page's own entrance animation to finish.
        try await Task.sleep(for: .seconds(1))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    @Test func freeStudentWithTrial() async throws {
        try await render("1-free-monthly-trial", PaywallScreen(autoplay: false),
                         entitlements: await entitlements(.free), purchases: await store(trial: true))
    }

    @Test func freeStudentYearly() async throws {
        try await render("2-free-yearly-trial", PaywallScreen(autoplay: false, plan: .pro, period: .yearly),
                         entitlements: await entitlements(.free), purchases: await store(trial: true))
    }

    @Test func trialAlreadyUsed() async throws {
        try await render("3-free-no-trial", PaywallScreen(autoplay: false),
                         entitlements: await entitlements(.free), purchases: await store(trial: false))
    }

    @Test func buildThatCannotBuy() async throws {
        try await render("4-no-store", PaywallScreen(autoplay: false),
                         entitlements: await entitlements(.free), purchases: PurchaseService(store: nil))
    }

    @Test func proSubscriberLooksAtPlus() async throws {
        try await render("5-pro-to-plus", PaywallScreen(autoplay: false, plan: .plus),
                         entitlements: await entitlements(.pro), purchases: await store(trial: false))
    }

    @Test func plusSubscriberLooksAtFree() async throws {
        try await render("6-plus-to-free", PaywallScreen(autoplay: false, plan: .free),
                         entitlements: await entitlements(.plus), purchases: await store(trial: false))
    }
}
