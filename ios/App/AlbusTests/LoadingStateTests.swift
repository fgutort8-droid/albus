import Foundation
import Testing
@testable import Albus

/// When the loading skeletons show, and when they must not. The pictures are in
/// `LoadingSnapshots`; these are the rules behind them.
@MainActor
@Suite("Loading skeletons")
struct LoadingStateTests {

    /// Offers arrive only when released, so a reload can be caught half-way.
    @MainActor
    private final class ReloadingStore: PurchaseStore {
        var holdOffers = false
        private var waiting: CheckedContinuation<Void, Never>?

        func identify(_ appUserID: String) async throws {}
        func offers() async throws -> [StoreOffer] {
            if holdOffers { await withCheckedContinuation { waiting = $0 } }
            return PurchaseServiceTests.catalogue
        }
        func release() {
            waiting?.resume()
            waiting = nil
        }
        var isHolding: Bool { waiting != nil }
        func purchase(productID: String) async throws -> Bool { true }
        func restore() async throws -> Bool { true }
        func manageSubscriptions() async throws {}
    }

    @Test("a paid plan shows the shape of its price only while it has none to show")
    func priceSkeletonRule() {
        // The App Store has not answered, and no price is to hand.
        #expect(PaywallScreen.showsPriceSkeleton(isFree: false, availability: .loading, hasOffer: false))
        // A price already fetched stays through a reload: it can still be bought.
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .loading, hasOffer: true))
        // Answered, unanswerable, or not for sale in this build: never a skeleton.
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .ready, hasOffer: true))
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .failed("x"), hasOffer: false))
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: false, availability: .unavailable, hasOffer: false))
        // Free has no price to wait for.
        #expect(!PaywallScreen.showsPriceSkeleton(isFree: true, availability: .loading, hasOffer: false))
    }

    @Test("prices arrive in place of their skeletons, and a reload keeps them on screen")
    func reloadKeepsPricesOnScreen() async throws {
        let store = ReloadingStore()
        let purchases = PurchaseService(store: store)
        func skeleton() -> Bool {
            PaywallScreen.showsPriceSkeleton(isFree: false, availability: purchases.availability,
                                             hasOffer: purchases.option(.plus, .monthly) != nil)
        }

        #expect(purchases.availability == .loading)
        #expect(skeleton(), "before the App Store answers, the shape of the price")

        await purchases.start(userID: UUID())
        #expect(purchases.availability == .ready)
        #expect(!skeleton(), "the storefront price, once it has arrived")

        store.holdOffers = true
        let reload = Task { await purchases.load() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while !store.isHolding, clock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        #expect(purchases.availability == .loading, "caught half-way through the reload")
        #expect(purchases.option(.plus, .monthly) != nil, "the first load's offers are kept")
        #expect(!skeleton(), "so their price and terms stay beside the buy button")

        store.release()
        await reload.value
        #expect(!skeleton())
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
