import Foundation
import Testing
@testable import Albus

/// Buying, restoring, and what the student is told, against a stand-in store.
@MainActor
@Suite("Purchases")
struct PurchaseServiceTests {

    // MARK: - Stand-ins

    @MainActor
    final class FakeStore: PurchaseStore {
        var identified: [String] = []
        var identifyError: PurchaseError?
        var offersResult: Result<[StoreOffer], PurchaseError> = .success(PurchaseServiceTests.catalogue)
        var purchaseResult: Result<Bool, PurchaseError> = .success(true)
        var restoreResult: Result<Bool, PurchaseError> = .success(true)
        var manageError: PurchaseError?
        var purchased: [String] = []
        var managed = 0

        func identify(_ appUserID: String) async throws {
            if let identifyError { throw identifyError }
            identified.append(appUserID)
        }

        func offers() async throws -> [StoreOffer] { try offersResult.get() }

        func purchase(productID: String) async throws -> Bool {
            purchased.append(productID)
            return try purchaseResult.get()
        }

        func restore() async throws -> Bool { try restoreResult.get() }

        func manageSubscriptions() async throws {
            managed += 1
            if let manageError { throw manageError }
        }
    }

    /// Serves one plan per fetch, repeating the last one.
    private actor PlanSequence: PlanReading {
        private var plans: [EntitlementService.Plan]
        private(set) var fetches = 0

        init(_ plans: [EntitlementService.Plan]) { self.plans = plans }

        func fetch() async throws -> EntitlementService.Plan? {
            fetches += 1
            return plans.count > 1 ? plans.removeFirst() : plans.first
        }
    }

    nonisolated private static func amount(_ text: String) -> Decimal { Decimal(string: text)! }

    nonisolated static let catalogue: [StoreOffer] = [
        StoreOffer(productID: "com.felipegutierrez.albus.plus.monthly", price: "€9.99",
                   amount: amount("9.99"), pricePerWeek: "€2.31", freeTrial: "3 days"),
        StoreOffer(productID: "com.felipegutierrez.albus.plus.annual", price: "€99.99",
                   amount: amount("99.99"), pricePerWeek: "€1.92", freeTrial: "3 days"),
        StoreOffer(productID: "com.felipegutierrez.albus.pro.monthly", price: "€17.99",
                   amount: amount("17.99"), pricePerWeek: "€4.15", freeTrial: nil),
        StoreOffer(productID: "com.felipegutierrez.albus.pro.annual", price: "€179.99",
                   amount: amount("179.99"), pricePerWeek: "€3.46", freeTrial: nil),
        // Something RevenueCat sells that this app does not know.
        StoreOffer(productID: "com.example.other", price: "€1.00",
                   amount: amount("1"), pricePerWeek: nil, freeTrial: nil),
    ]

    private static let student = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    private static func plan(_ tier: EntitlementService.Tier,
                             expires: Date? = .now.addingTimeInterval(86_400)) -> EntitlementService.Plan {
        let free = EntitlementService.Plan.freeFallback
        return EntitlementService.Plan(
            tier: tier, displayName: PurchaseFlow.name(tier), priceCents: 0, currency: "EUR",
            expiresAt: tier == .free ? nil : expires,
            tasks: free.tasks, aiPlans: free.aiPlans, grader: free.grader, rubrics: free.rubrics,
            toolsAccess: free.toolsAccess, curriculumIntelligence: false, advancedModels: false)
    }

    private func started(_ store: FakeStore = FakeStore()) async -> (PurchaseService, FakeStore) {
        let service = PurchaseService(store: store)
        await service.start(userID: Self.student)
        return (service, store)
    }

    // MARK: - Loading

    @Test("a build without a key cannot buy, and says so")
    func noKeyNoPurchases() async {
        let service = PurchaseService(store: nil)
        await service.start(userID: Self.student)

        #expect(service.availability == .unavailable)
        #expect(service.options.isEmpty)
        let option = PurchaseService.option(from: Self.catalogue[0])!
        if case .failed = await service.purchase(option) {} else { Issue.record("purchase did not fail") }
        if case .failed = await service.restore() {} else { Issue.record("restore did not fail") }
        #expect(await service.manageSubscriptions() == false)
    }

    @Test("the store is told the Supabase account id, lowercased, and nothing else")
    func identifiesAsTheAccount() async {
        let (service, store) = await started()

        #expect(store.identified == ["6f9619ff-8b86-d011-b42d-00c04fc964ff"])
        #expect(service.availability == .ready)
    }

    @Test("no account, no store traffic")
    func waitsForAnAccount() async {
        let store = FakeStore()
        let service = PurchaseService(store: store)
        await service.start(userID: nil)

        #expect(store.identified.isEmpty)
        #expect(service.options.isEmpty)
    }

    @Test("starting again for the same account does not log in again")
    func identifiesOnce() async {
        let (service, store) = await started()
        await service.start(userID: Self.student)

        #expect(store.identified.count == 1)
    }

    @Test("only the four Albus products are offered")
    func unknownProductsAreDropped() async {
        let (service, _) = await started()

        #expect(service.options.count == 4)
        #expect(service.option(.plus, .monthly)?.price == "€9.99")
        #expect(service.option(.plus, .yearly)?.price == "€99.99")
        #expect(service.option(.pro, .monthly)?.price == "€17.99")
        #expect(service.option(.pro, .yearly)?.price == "€179.99")
    }

    @Test("the weekly price is shown for yearly plans only")
    func perWeekOnlyForYearly() async {
        let (service, _) = await started()

        #expect(service.option(.plus, .yearly)?.pricePerWeek == "€1.92")
        #expect(service.option(.plus, .monthly)?.pricePerWeek == nil)
    }

    @Test("the yearly saving comes from the store's own prices, rounded down")
    func yearlySaving() async {
        let (service, _) = await started()

        // 12 × 9.99 = 119.88 against 99.99: 16.6%. Pro: 215.88 against 179.99.
        #expect(service.yearlySaving(.plus) == 16)
        #expect(service.yearlySaving(.pro) == 16)
        #expect(service.yearlySaving(.free) == nil)
    }

    @Test("a store that cannot identify the student leaves buying off, with a reason")
    func identifyFailure() async {
        let store = FakeStore()
        store.identifyError = .offline
        let (service, _) = await started(store)

        #expect(service.availability == .failed(PurchaseService.message(for: PurchaseError.offline)))
    }

    @Test("an empty offering is a failure, not a paywall with nothing to buy")
    func emptyOffering() async {
        let store = FakeStore()
        store.offersResult = .success([])
        let (service, _) = await started(store)

        if case .failed = service.availability {} else {
            Issue.record("expected a failure, got \(service.availability)")
        }
    }

    @Test("a failed load can be retried")
    func loadRetries() async {
        let store = FakeStore()
        store.offersResult = .failure(.offline)
        let (service, _) = await started(store)
        store.offersResult = .success(Self.catalogue)

        await service.load()

        #expect(service.availability == .ready)
    }

    // MARK: - Buying

    @Test("each store answer becomes one outcome")
    func purchaseOutcomes() async {
        let (service, store) = await started()
        let plus = service.option(.plus, .monthly)!

        #expect(await service.purchase(plus) == .purchased)
        #expect(store.purchased == ["com.felipegutierrez.albus.plus.monthly"])

        store.purchaseResult = .success(false)
        #expect(await service.purchase(plus) == .cancelled)

        store.purchaseResult = .failure(.cancelled)
        #expect(await service.purchase(plus) == .cancelled)

        store.purchaseResult = .failure(.pending)
        #expect(await service.purchase(plus) == .pending)

        store.purchaseResult = .failure(.notAllowed)
        #expect(await service.purchase(plus)
                == .failed(PurchaseService.message(for: PurchaseError.notAllowed)))
        #expect(!service.isWorking)
    }

    @Test("restore answers")
    func restoreOutcomes() async {
        let (service, store) = await started()

        #expect(await service.restore() == .restored)
        store.restoreResult = .success(false)
        #expect(await service.restore() == .nothingToRestore)
        store.restoreResult = .failure(.offline)
        #expect(await service.restore()
                == .failed(PurchaseService.message(for: PurchaseError.offline)))
    }

    @Test("a bought plan counts once the server reports it")
    func buyWaitsForTheServer() async {
        let (service, _) = await started()
        let reader = PlanSequence([Self.plan(.free), Self.plan(.free), Self.plan(.pro)])
        let entitlements = EntitlementService(reader: reader)

        let result = await PurchaseFlow.buy(service.option(.pro, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 5, interval: .zero)

        #expect(result == .unlocked)
        #expect(entitlements.tier == .pro)
        #expect(await reader.fetches == 3)
    }

    @Test("a plan the server has not reported yet is on its way, not failed")
    func buySlowServer() async {
        let (service, _) = await started()
        let entitlements = EntitlementService(reader: PlanSequence([Self.plan(.free)]))

        let result = await PurchaseFlow.buy(service.option(.plus, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 3, interval: .zero)

        guard case .message(let text) = result else {
            Issue.record("expected a message, got \(result)")
            return
        }
        #expect(text.contains("Payment done"))
        #expect(!text.localizedCaseInsensitiveContains("fail"))
    }

    @Test("a lower plan starts at the next renewal, so nothing is awaited")
    func downgradeWaitsForRenewal() async {
        let (service, _) = await started()
        let reader = PlanSequence([Self.plan(.pro)])
        let entitlements = EntitlementService(reader: reader)
        await entitlements.refresh()

        let result = await PurchaseFlow.buy(service.option(.plus, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 3, interval: .zero)

        #expect(result == .message("You'll move to Plus at your next renewal."))
        #expect(await reader.fetches == 1)
    }

    @Test("an expired Pro row does not make Plus look like a downgrade")
    func expiredPlanIsFree() async {
        let (service, _) = await started()
        let reader = PlanSequence([Self.plan(.pro, expires: .now.addingTimeInterval(-60)),
                                   Self.plan(.plus)])
        let entitlements = EntitlementService(reader: reader)
        await entitlements.refresh()

        let result = await PurchaseFlow.buy(service.option(.plus, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 3, interval: .zero)

        #expect(result == .unlocked)
    }

    @Test("Ask to Buy says who it is waiting for")
    func pendingPurchase() async {
        let store = FakeStore()
        store.purchaseResult = .failure(.pending)
        let (service, _) = await started(store)
        let entitlements = EntitlementService(reader: PlanSequence([Self.plan(.free)]))

        let result = await PurchaseFlow.buy(service.option(.plus, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 1, interval: .zero)

        #expect(result == .message("Waiting for approval. Plus switches on once it's approved."))
    }

    @Test("closing Apple's sheet says nothing")
    func cancelledPurchase() async {
        let store = FakeStore()
        store.purchaseResult = .success(false)
        let (service, _) = await started(store)
        let entitlements = EntitlementService(reader: PlanSequence([Self.plan(.free)]))

        let result = await PurchaseFlow.buy(service.option(.plus, .monthly)!, purchases: service,
                                            entitlements: entitlements,
                                            attempts: 1, interval: .zero)

        #expect(result == .nothing)
    }

    @Test("a restore reports the plan the server moved")
    func restoreReportsThePlan() async {
        let (service, _) = await started()
        let entitlements = EntitlementService(reader: PlanSequence([Self.plan(.free), Self.plan(.plus)]))

        let text = await PurchaseFlow.restore(purchases: service, entitlements: entitlements,
                                              attempts: 3, interval: .zero)

        #expect(text == "Restored. You're on Plus.")
    }

    @Test("an Apple ID with nothing to restore is told so")
    func restoreNothing() async {
        let store = FakeStore()
        store.restoreResult = .success(false)
        let (service, _) = await started(store)
        let entitlements = EntitlementService(reader: PlanSequence([Self.plan(.free)]))

        let text = await PurchaseFlow.restore(purchases: service, entitlements: entitlements,
                                              attempts: 1, interval: .zero)

        #expect(text == "This Apple ID has no active Albus subscription to restore.")
    }

    @Test("when Apple's sheet can't open, its web page does")
    func manageFallsBackToTheWeb() async {
        let store = FakeStore()
        store.manageError = .store
        let (service, _) = await started(store)
        var opened: [URL] = []

        await PurchaseFlow.manageSubscription(purchases: service) { opened.append($0) }

        #expect(store.managed == 1)
        #expect(opened == [AppLinks.manageSubscriptions])
    }

    // MARK: - Which key a build uses

    private static func info(_ values: [String: String]) -> (String) -> Any? {
        { values[$0] }
    }

    @Test("debug builds prefer the Test Store key")
    func debugPrefersTestStore() {
        let key = PurchaseConfig.apiKey(
            info: Self.info(["REVENUECAT_TEST_API_KEY": "test_abc", "REVENUECAT_API_KEY": "appl_xyz"]),
            arguments: [], isDebug: true)
        #expect(key == "test_abc")
    }

    @Test("release builds never use a Test Store key, wherever it was put")
    func releaseRefusesTestStore() {
        #expect(PurchaseConfig.apiKey(
            info: Self.info(["REVENUECAT_TEST_API_KEY": "test_abc", "REVENUECAT_API_KEY": "appl_xyz"]),
            arguments: [], isDebug: false) == "appl_xyz")
        #expect(PurchaseConfig.apiKey(
            info: Self.info(["REVENUECAT_API_KEY": "test_abc"]),
            arguments: [], isDebug: false) == nil)
    }

    @Test("an unset or unexpanded setting is no key")
    func unsetSettings() {
        for raw in ["", "   ", "$(REVENUECAT_API_KEY)"] {
            #expect(PurchaseConfig.apiKey(info: Self.info(["REVENUECAT_API_KEY": raw]),
                                          arguments: [], isDebug: false) == nil)
        }
        #expect(PurchaseConfig.apiKey(info: Self.info([:]), arguments: [], isDebug: true) == nil)
    }

    @Test("UI tests run without a store")
    func uiTestsHaveNoStore() {
        let info = Self.info(["REVENUECAT_TEST_API_KEY": "test_abc"])
        #expect(PurchaseConfig.apiKey(info: info, arguments: ["-albus.debug.noPurchases"],
                                      isDebug: true) == nil)
        #expect(PurchaseConfig.apiKey(info: info, arguments: ["-albus.debug.assumeSignedIn"],
                                      isDebug: true) == nil)
    }
}
