import Foundation
import RevenueCat

/// Buying Plus and Pro, through RevenueCat and the App Store.
///
/// A purchase here is only half of the story. The plan itself comes from our
/// server, which hears about every purchase from RevenueCat's signed webhook,
/// so after the App Store says yes the paywall waits for `EntitlementService`
/// to see the new plan instead of trusting the phone. A phone that says Pro
/// while the server says Free would be refused by the server anyway; the
/// reverse would lock out a student who paid.
@Observable
@MainActor
final class PurchaseService {

    enum Period: String, CaseIterable, Identifiable, Sendable {
        case monthly, yearly
        var id: String { rawValue }
        var title: String { self == .monthly ? "Monthly" : "Yearly" }
        var unit: String { self == .monthly ? "per month" : "per year" }
    }

    /// One thing a student can buy, priced by the App Store for their country.
    struct Option: Identifiable, Equatable, Sendable {
        let tier: EntitlementService.Tier
        let period: Period
        let productID: String
        /// The billed price, localized by the App Store. Never a figure
        /// written in this app: the storefront decides it.
        let price: String
        let amount: Decimal
        /// The same price per week, for the small print under a yearly plan.
        let pricePerWeek: String?
        /// "3 days", when the product has a free trial *and* this Apple ID can
        /// still take it. Apple gives one trial per subscription group.
        let freeTrial: String?
        var id: String { productID }
    }

    enum Availability: Equatable, Sendable {
        /// This build has no RevenueCat key. Nothing can be bought, and prices
        /// fall back to the display copy `PricingTests` pins to the server.
        case unavailable
        case loading
        case ready
        case failed(String)
    }

    enum Outcome: Equatable, Sendable {
        case purchased
        case cancelled
        /// Ask to Buy: a parent has to approve. The plan arrives on its own
        /// once they do, through the same webhook as any purchase.
        case pending
        case failed(String)
    }

    enum RestoreOutcome: Equatable, Sendable {
        case restored
        case nothingToRestore
        case failed(String)
    }

    /// What App Store Connect and RevenueCat sell, and what each product is.
    /// `public.subscription_products` maps the same four ids on the server.
    static let catalogue: [String: (tier: EntitlementService.Tier, period: Period)] = [
        "com.felipegutierrez.albus.plus.monthly": (.plus, .monthly),
        "com.felipegutierrez.albus.plus.annual": (.plus, .yearly),
        "com.felipegutierrez.albus.pro.monthly": (.pro, .monthly),
        "com.felipegutierrez.albus.pro.annual": (.pro, .yearly),
    ]

    private(set) var availability: Availability
    private(set) var options: [Option] = []
    private(set) var isWorking = false

    private let store: (any PurchaseStore)?
    private var identifiedAs: String?

    init(store: (any PurchaseStore)? = RevenueCatStore.fromBundle()) {
        self.store = store
        self.availability = store == nil ? .unavailable : .loading
    }

    var isReady: Bool { availability == .ready }

    func option(_ tier: EntitlementService.Tier, _ period: Period) -> Option? {
        options.first { $0.tier == tier && $0.period == period }
    }

    /// What paying yearly saves against twelve monthly payments, as a whole
    /// percentage rounded down, from the two App Store prices so the claim
    /// holds in every country. Nil unless it saves at least 1%.
    ///
    /// A percentage rather than "months free": at launch prices a year saves
    /// just under two months, and rounding that down to "1 month free" would
    /// undersell it while rounding up would overstate it.
    func yearlySaving(_ tier: EntitlementService.Tier) -> Int? {
        guard let monthly = option(tier, .monthly), let yearly = option(tier, .yearly),
              monthly.amount > 0 else { return nil }
        let twelve = monthly.amount * 12
        let saved = (twelve - yearly.amount) / twelve * 100
        let percent = NSDecimalNumber(decimal: saved).doubleValue.rounded(.down)
        return percent >= 1 ? Int(percent) : nil
    }

    /// Tells RevenueCat who is buying, then loads the prices.
    ///
    /// The App User ID is the Supabase user id and nothing else. The webhook
    /// grants a plan only to an id it finds in `auth.users`; a purchase made
    /// under RevenueCat's own anonymous id would reach nobody.
    func start(userID: UUID?) async {
        guard let store, let userID else { return }
        let appUserID = userID.uuidString.lowercased()
        if identifiedAs != appUserID {
            do {
                try await store.identify(appUserID)
                identifiedAs = appUserID
            } catch {
                availability = .failed(Self.message(for: error))
                return
            }
        }
        await load()
    }

    func load() async {
        guard let store, identifiedAs != nil else { return }
        availability = .loading
        do {
            options = try await store.offers().compactMap(Self.option(from:))
            availability = options.isEmpty
                ? .failed("No plans are on sale right now. Try again later.")
                : .ready
        } catch {
            availability = .failed(Self.message(for: error))
        }
    }

    func purchase(_ option: Option) async -> Outcome {
        guard let store, identifiedAs != nil, !isWorking else {
            return .failed("Purchases aren't available right now.")
        }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await store.purchase(productID: option.productID) ? .purchased : .cancelled
        } catch PurchaseError.pending {
            return .pending
        } catch PurchaseError.cancelled {
            return .cancelled
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    func restore() async -> RestoreOutcome {
        guard let store, identifiedAs != nil, !isWorking else {
            return .failed("Restoring isn't available right now.")
        }
        isWorking = true
        defer { isWorking = false }
        do {
            return try await store.restore() ? .restored : .nothingToRestore
        } catch {
            return .failed(Self.message(for: error))
        }
    }

    /// Apple's own subscription sheet. False when it could not be shown, so
    /// the caller can open the Settings page instead.
    func manageSubscriptions() async -> Bool {
        guard let store, identifiedAs != nil else { return false }
        do {
            try await store.manageSubscriptions()
            return true
        } catch {
            return false
        }
    }

    static func option(from offer: StoreOffer) -> Option? {
        guard let entry = catalogue[offer.productID] else { return nil }
        return Option(tier: entry.tier, period: entry.period, productID: offer.productID,
                      price: offer.price, amount: offer.amount,
                      pricePerWeek: entry.period == .yearly ? offer.pricePerWeek : nil,
                      freeTrial: offer.freeTrial)
    }

    static func message(for error: Error) -> String {
        switch error as? PurchaseError {
        case .offline:
            "No connection. Try again when you're online."
        case .notAllowed:
            "Purchases are turned off on this device. They can be allowed in Screen Time."
        case .notOnSale:
            "That plan isn't on sale right now."
        case .alreadyOwned:
            "This Apple ID already has that plan. Try Restore."
        case .inProgress:
            "That purchase is already in progress."
        case .store:
            "The App Store had a problem. Try again in a moment."
        case .pending:
            "Waiting for approval."
        case .cancelled:
            "Cancelled."
        case .other, nil:
            "Something went wrong with the App Store. Try again."
        }
    }
}

// MARK: - The store seam

/// What the service needs from a store, in the app's own words, so tests can
/// stand in for RevenueCat and RevenueCat's types stay in one file.
@MainActor
protocol PurchaseStore: AnyObject {
    func identify(_ appUserID: String) async throws
    func offers() async throws -> [StoreOffer]
    /// True when the store completed the purchase, false when the student
    /// backed out of Apple's sheet.
    func purchase(productID: String) async throws -> Bool
    /// True when this Apple ID has an active subscription to restore.
    func restore() async throws -> Bool
    func manageSubscriptions() async throws
}

struct StoreOffer: Equatable, Sendable {
    let productID: String
    let price: String
    let amount: Decimal
    let pricePerWeek: String?
    let freeTrial: String?
}

enum PurchaseError: Error, Equatable, Sendable {
    case cancelled, pending, offline, notAllowed, notOnSale, alreadyOwned, inProgress, store, other
}

/// Which RevenueCat key this build uses.
enum PurchaseConfig {
    /// The key, or nil for a build that cannot buy.
    ///
    /// Debug builds prefer the Test Store key, which buys without Apple.
    /// Release never reads it, and project.yml blanks it there too: an app
    /// submitted with a Test Store key sells nothing.
    static func apiKey(_ bundle: Bundle = .main) -> String? {
#if DEBUG
        let isDebug = true
#else
        let isDebug = false
#endif
        return apiKey(info: { bundle.object(forInfoDictionaryKey: $0) },
                      arguments: ProcessInfo.processInfo.arguments,
                      isDebug: isDebug)
    }

    static func apiKey(info: (String) -> Any?, arguments: [String], isDebug: Bool) -> String? {
        if isDebug {
            // UI tests: deterministic display prices, and no store traffic.
            // The assumed session has no server credential, so buying could
            // not work anyway.
            if arguments.contains("-albus.debug.noPurchases")
                || arguments.contains("-albus.debug.assumeSignedIn") {
                return nil
            }
            if let test = value(info("REVENUECAT_TEST_API_KEY")) { return test }
        }
        guard let key = value(info("REVENUECAT_API_KEY")) else { return nil }
        // A Test Store key pasted into the wrong setting still never ships:
        // the build that goes to Apple buys nothing rather than pretending to.
        if !isDebug && key.hasPrefix("test_") { return nil }
        return key
    }

    /// An unset build setting arrives as an empty string, or unexpanded.
    private static func value(_ raw: Any?) -> String? {
        guard let raw = raw as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.hasPrefix("$(") ? nil : value
    }
}

// MARK: - RevenueCat

@MainActor
final class RevenueCatStore: PurchaseStore {
    private let apiKey: String
    /// RevenueCat buys a `Package`, so the ones last loaded are kept by product.
    private var packages: [String: Package] = [:]

    init(apiKey: String) {
        self.apiKey = apiKey
    }

    static func fromBundle(_ bundle: Bundle = .main) -> RevenueCatStore? {
        PurchaseConfig.apiKey(bundle).map { RevenueCatStore(apiKey: $0) }
    }

    func identify(_ appUserID: String) async throws {
        guard Purchases.isConfigured else {
            Purchases.configure(with: RevenueCat.Configuration.Builder(withAPIKey: apiKey)
                .with(appUserID: appUserID)
                .build())
            return
        }
        guard Purchases.shared.appUserID != appUserID else { return }
        do {
            _ = try await Purchases.shared.logIn(appUserID)
        } catch {
            throw Self.translate(error)
        }
    }

    func offers() async throws -> [StoreOffer] {
        let offerings: Offerings
        do {
            offerings = try await Purchases.shared.offerings()
        } catch {
            throw Self.translate(error)
        }
        var loaded: [String: Package] = [:]
        var offers: [StoreOffer] = []
        for package in offerings.current?.availablePackages ?? [] {
            let product = package.storeProduct
            loaded[product.productIdentifier] = package
            offers.append(StoreOffer(
                productID: product.productIdentifier,
                price: product.localizedPriceString,
                amount: product.price,
                pricePerWeek: product.localizedPricePerWeek,
                freeTrial: await Self.freeTrial(for: product)))
        }
        packages = loaded
        return offers
    }

    func purchase(productID: String) async throws -> Bool {
        guard let package = packages[productID] else { throw PurchaseError.notOnSale }
        do {
            return try await !Purchases.shared.purchase(package: package).userCancelled
        } catch {
            let translated = Self.translate(error)
            if translated == .cancelled { return false }
            throw translated
        }
    }

    func restore() async throws -> Bool {
        do {
            return try await !Purchases.shared.restorePurchases().entitlements.active.isEmpty
        } catch {
            throw Self.translate(error)
        }
    }

    func manageSubscriptions() async throws {
        do {
            try await Purchases.shared.showManageSubscriptions()
        } catch {
            throw Self.translate(error)
        }
    }

    /// A free trial this Apple ID can still take, as "3 days".
    private static func freeTrial(for product: StoreProduct) async -> String? {
        guard let intro = product.introductoryDiscount, intro.paymentMode == .freeTrial else {
            return nil
        }
        let eligibility = await Purchases.shared.checkTrialOrIntroDiscountEligibility(product: product)
        guard eligibility == .eligible else { return nil }
        return describe(value: intro.subscriptionPeriod.value, unit: intro.subscriptionPeriod.unit)
    }

    static func describe(value: Int, unit: SubscriptionPeriod.Unit) -> String {
        let noun: String
        switch unit {
        case .day: noun = "day"
        case .week: noun = "week"
        case .month: noun = "month"
        case .year: noun = "year"
        @unknown default: noun = "period"
        }
        return "\(value) \(noun)\(value == 1 ? "" : "s")"
    }

    static func translate(_ error: Error) -> PurchaseError {
        guard let code = error as? RevenueCat.ErrorCode else { return .other }
        switch code {
        case .purchaseCancelledError: return .cancelled
        case .paymentPendingError: return .pending
        case .networkError: return .offline
        case .purchaseNotAllowedError: return .notAllowed
        case .productNotAvailableForPurchaseError: return .notOnSale
        case .productAlreadyPurchasedError: return .alreadyOwned
        case .operationAlreadyInProgressForProductError: return .inProgress
        case .storeProblemError: return .store
        default: return .other
        }
    }
}
