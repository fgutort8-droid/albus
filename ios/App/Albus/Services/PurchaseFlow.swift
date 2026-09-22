import Foundation

/// What happens around a purchase, wherever it starts.
///
/// The App Store saying yes is not the plan changing. The plan changes when
/// our server hears from RevenueCat's webhook, usually a few seconds later, so
/// every path here waits for `EntitlementService` to report it and turns each
/// outcome into one sentence a student can act on.
@MainActor
enum PurchaseFlow {

    enum BuyResult: Equatable {
        /// The server reports the plan that was bought.
        case unlocked
        /// Something the student should read: a failure, a pending approval,
        /// or a plan that is on its way.
        case message(String)
        /// The student closed Apple's sheet. Nothing to say.
        case nothing
    }

    static func buy(_ option: PurchaseService.Option,
                    purchases: PurchaseService,
                    entitlements: EntitlementService,
                    attempts: Int = 10,
                    interval: Duration = .seconds(2)) async -> BuyResult {
        let before: EntitlementService.Tier = entitlements.isPaid ? entitlements.tier : .free
        switch await purchases.purchase(option) {
        case .purchased:
            // Apple moves a subscriber down a level at their next renewal,
            // not now, so there is nothing to wait for.
            if option.tier < before {
                return .message("You'll move to \(name(option.tier)) at your next renewal.")
            }
            if await entitlements.waitForPaidPlan(atLeast: option.tier,
                                                  attempts: attempts, interval: interval) {
                return .unlocked
            }
            // The webhook retries for hours, so a slow one still lands. Saying
            // "failed" here would send a student who paid to buy again.
            return .message("Payment done. \(name(option.tier)) can take a minute to switch on, "
                            + "and it will by itself.")
        case .pending:
            return .message("Waiting for approval. \(name(option.tier)) switches on once it's approved.")
        case .cancelled:
            return .nothing
        case .failed(let message):
            return .message(message)
        }
    }

    /// Restores this Apple ID's subscription onto this account. On a new phone
    /// that is a new account: RevenueCat moves the purchase and the server
    /// moves the plan, and its recent AI use, with it.
    static func restore(purchases: PurchaseService,
                        entitlements: EntitlementService,
                        attempts: Int = 10,
                        interval: Duration = .seconds(2)) async -> String {
        switch await purchases.restore() {
        case .restored:
            if await entitlements.waitForPaidPlan(attempts: attempts, interval: interval) {
                return "Restored. You're on \(name(entitlements.tier))."
            }
            return "Found your subscription. It can take a minute to switch on, and it will by itself."
        case .nothingToRestore:
            return "This Apple ID has no active Albus subscription to restore."
        case .failed(let message):
            return message
        }
    }

    /// Apple's own subscription sheet, or its web page when the sheet can't be
    /// shown. Cancelling happens there; Albus never cancels on its own.
    static func manageSubscription(purchases: PurchaseService, open: (URL) -> Void) async {
        if await !purchases.manageSubscriptions() {
            open(AppLinks.manageSubscriptions)
        }
    }

    static func name(_ tier: EntitlementService.Tier) -> String {
        switch tier {
        case .free: "Free"
        case .plus: "Plus"
        case .pro: "Pro"
        }
    }
}
