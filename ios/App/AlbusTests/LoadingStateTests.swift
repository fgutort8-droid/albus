import Foundation
import Testing
@testable import Albus

/// When the loading skeletons show, and when they must not. The pictures are in
/// `LoadingSnapshots`; these are the rules behind them.
@MainActor
@Suite("Loading skeletons")
struct LoadingStateTests {

    /// Offers arrive only when released, so a reload can be caught half-way.
    /// Once released, a request that arrives late is answered at once, so the
    /// test can never be left waiting on it.
    @MainActor
    private final class ReloadingStore: PurchaseStore {
        var holdOffers = false
        private var released = false
        private var waiting: CheckedContinuation<Void, Never>?

        private(set) var purchases = 0

        func identify(_ appUserID: String) async throws {}
        func offers() async throws -> [StoreOffer] {
            if holdOffers, !released { await withCheckedContinuation { waiting = $0 } }
            return PurchaseServiceTests.catalogue
        }
        func release() {
            released = true
            waiting?.resume()
            waiting = nil
        }
        var isHolding: Bool { waiting != nil }
        func purchase(productID: String) async throws -> Bool {
            purchases += 1
            return true
        }
        func restore() async throws -> Bool { true }
        func manageSubscriptions() async throws {}
    }

    @Test("a paid plan shows the shape of its price while the App Store is asked")
    func priceSkeletonRule() {
        #expect(PaywallScreen.showsPriceSkeleton(isFree: false, availability: .loading))
        // Answered, unanswerable, or not for sale in this build: never a skeleton.
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .ready))
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .failed("x")))
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .unavailable))
        // Free has no price to wait for.
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: true, availability: .loading))
    }

    /// The reported bug: a reload kept the last prices on screen and let them
    /// be bought, though the App Store's price might have changed.
    @Test("during a reload, no old price is shown or sold; the new ones arrive in place")
    func reloadHoldsPurchases() async throws {
        let store = ReloadingStore()
        let purchases = PurchaseService(store: store)
        func skeleton() -> Bool {
            PaywallScreen.showsPriceSkeleton(isFree: false, availability: purchases.availability)
        }

        #expect(purchases.availability == .loading)
        #expect(skeleton(), "before the App Store answers, the shape of the price")

        await purchases.start(userID: UUID())
        #expect(purchases.availability == .ready)
        #expect(!skeleton(), "the storefront price, once it has arrived")
        let offer = try #require(purchases.option(.plus, .monthly))

        store.holdOffers = true
        let reload = Task { await purchases.load() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !store.isHolding, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        let caught = store.isHolding
        #expect(caught, "the reload reached the App Store within two seconds")
        if caught {
            #expect(purchases.availability == .loading, "caught half-way through the reload")
            #expect(skeleton(), "the kept price may be stale: its shape, not its amount")
            #expect(await purchases.purchase(offer) == .failed("Still loading prices. Try again in a moment."))
            #expect(store.purchases == 0, "nothing reached the App Store")
        }

        // Released either way, so a reload that was slow to start still ends.
        store.release()
        await reload.value
        #expect(!skeleton())
        #expect(await purchases.purchase(offer) == .purchased, "sold once the answer is in")
        #expect(store.purchases == 1)
    }

    @Test("the marking skeleton sketches one card per rubric criterion, within reason")
    func skeletonCriteriaFollowTheRubric() {
        #expect(GraderScreen.skeletonCriteria(rubricItems: 0) == 3, "blind: three")
        #expect(GraderScreen.skeletonCriteria(rubricItems: 4) == 4)
        #expect(GraderScreen.skeletonCriteria(rubricItems: 6) == 6)
        #expect(GraderScreen.skeletonCriteria(rubricItems: 11) == 6, "capped: it is a sketch")
    }

    @Test("the result and its skeleton are laid out in one shared order")
    func resultOrderIsShared() {
        // Both views iterate this list; the basis must lead, before anything
        // that looks like a mark.
        #expect(GradeResultSection.allCases.first == .basis)
        #expect(GradeResultSection.allCases == [.basis, .headline, .improvements, .feedback, .criteria])
    }
}
