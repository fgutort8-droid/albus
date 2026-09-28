import SwiftUI
import Testing
import UIKit
@testable import Albus

/// The loading skeletons, drawn to PNG files for a person to look at. No
/// network: the store is a stand-in that never answers.
///
/// Off unless asked for, like `PaywallSnapshots`, because a picture is not an
/// assertion:
///
///     TEST_RUNNER_ALBUS_SNAPSHOT_DIR=/tmp/loading xcodebuild test \
///       ... -only-testing:AlbusTests/LoadingSnapshots
@MainActor
@Suite("Loading snapshots",
       .enabled(if: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"] != nil))
struct LoadingSnapshots {

    private actor FixedPlan: PlanReading {
        func fetch() async throws -> EntitlementService.Plan? { .freeFallback }
    }

    private func render(_ name: String, _ view: some View) async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["ALBUS_SNAPSHOT_DIR"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let scene = try #require(UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 393, height: 852)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }

        // Past the page's entrance animation, and mid-way through a shine.
        try await Task.sleep(for: .seconds(1.2))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try #require(image.pngData()).write(to: directory.appendingPathComponent("\(name).png"))
    }

    @Test func paywallWhilePricesLoad() async throws {
        // Never started, so it stays loading: the App Store has not answered.
        let purchases = PurchaseService(store: PurchaseServiceTests.FakeStore())
        #expect(purchases.availability == .loading)
        let entitlements = EntitlementService(reader: FixedPlan())
        await entitlements.refresh()
        try await render("1-paywall-prices-loading",
                         PaywallScreen(autoplay: false)
                             .environment(entitlements)
                             .environment(purchases))
    }

    @Test func markingFeedbackOnItsWay() async throws {
        try await render("2-marking-skeleton",
                         ZStack {
                             BackgroundGradient()
                             ScrollView {
                                 GradeResultSkeleton(criteria: 4)
                                     .padding(.horizontal, Tokens.Spacing.xl)
                                     .padding(.top, 60)
                             }
                         })
    }
}
