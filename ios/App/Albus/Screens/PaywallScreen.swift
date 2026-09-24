import SwiftUI
import AlbusCore

/// Albus Plus.
///
/// A port of `paywall-v2.jsx` from the Albus design project. The design opens
/// full-bleed on a night scene — Albus flying up to a violet moon, landing,
/// planting a check badge — then zooms that scene down into an arched hero
/// panel while the page content rises underneath it.
///
/// The intro is skippable by tapping, and skipped entirely under Reduce Motion:
/// a three-second animation between a student and a price is a toll, not a
/// flourish, and the people most likely to be hurt by it are the ones who asked
/// the system for less movement.
struct PaywallScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(EntitlementService.self) private var entitlements
    @Environment(PurchaseService.self) private var purchases
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the intro has got to. `flight` is full-bleed, `hero` is the zoom
    /// down into the panel, `done` releases the page to scroll.
    private enum Phase { case flight, hero, done }

    /// Whether the intro plays. Mirrors the source component's `autoplay` prop,
    /// and lets a snapshot render the settled screen rather than frame one.
    var autoplay: Bool = true

    @State private var phase: Phase
    @State private var plan: Plan
    @State private var period: PurchaseService.Period
    /// One sentence about the last thing the student tried: a failure, an
    /// approval still pending, a plan on its way.
    @State private var notice: String?
    /// Between tapping buy or restore and the server reporting the plan.
    @State private var isConfirming = false
    @State private var runID = 0

    /// `plan` and `period` are only where the screen starts; the student
    /// changes both. Snapshots use them to render each state.
    init(autoplay: Bool = true, plan: Plan = .plus, period: PurchaseService.Period = .monthly) {
        self.autoplay = autoplay
        _phase = State(initialValue: autoplay ? .flight : .done)
        _plan = State(initialValue: plan)
        _period = State(initialValue: period)
    }

    // Geometry from the design, in points.
    private let heroTop: CGFloat = 44
    private let heroInset: CGFloat = 16
    // 310 in the design, which was drawn for a screen whose content
    // started below the fold anyway. At three plans the cards have to
    // clear it on a 667pt phone, and 210 is what does that.
    private let heroHeight: CGFloat = 210
    private let arch: CGFloat = 120

    /// The three plans, as a student compares them.
    ///
    /// The numbers here are *display* copy; `public.plans` is what enforces
    /// them, read by the gate and the meter alike. They are written out rather
    /// than fetched because a paywall that renders blank while a request is in
    /// flight sells nothing — and because being wrong here costs a wrong price
    /// on a card, never a wrong limit. `PricingTests` is what stops the two
    /// drifting apart.
    enum Plan: String, CaseIterable, Identifiable {
        case free, plus, pro
        var id: String { rawValue }

        var title: String {
            switch self {
            case .free: "Free"
            case .plus: "Plus"
            case .pro:  "Pro"
            }
        }

        var tier: EntitlementService.Tier {
            switch self {
            case .free: .free
            case .plus: .plus
            case .pro:  .pro
            }
        }

        /// Cents, matching `public.plans.price_cents`. The fallback price: once
        /// the App Store has priced a plan for this storefront, that is what
        /// the card shows.
        var priceCents: Int {
            switch self {
            case .free: 0
            case .plus: 999
            case .pro:  1799
            }
        }

        var price: String {
            priceCents == 0 ? "Free" : String(format: "€%.2f", Double(priceCents) / 100)
        }

        var period: String { priceCents == 0 ? "always" : "per month" }

        /// The one line that says why this plan exists. Every tier gets one,
        /// including Free — a plan with no stated purpose reads as a trap.
        var pitch: String {
            switch self {
            case .free: "The planner, in full."
            case .plus: "Albus marks your work."
            case .pro:  "More marking, and no limits."
            }
        }

        var tag: String? { self == .plus ? "MOST PICKED" : nil }

        /// The four things that change across plans, in the same order every
        /// time, so the eye can run down a column rather than read three lists.
        ///
        /// Deliberately not a forty-row feature matrix. A student deciding
        /// between three prices needs to know what the next €7 buys; a wall of
        /// ticks answers a question nobody asked.
        var lines: [(String, String)] {
            switch self {
            case .free:
                [("5 AI plans a week", "After that, Albus plans on your phone."),
                 ("5 active tasks", "Planned, scheduled, and rebuilt when your week moves."),
                 ("3 saved rubrics", "Paste a mark scheme once and reuse it."),
                 ("No marking", "The Grader needs Plus."),
                 ("The core tools", "The study tools Albus picks for a step.")]
            case .plus:
                [("Unlimited AI plans", "A step-by-step plan for every assignment."),
                 ("10 active tasks", "For a term carrying more than one deadline."),
                 ("5 saved rubrics", "Paste a mark scheme once and reuse it."),
                 ("2 markings a week", "Your work, your rubric, a real grade."),
                 ("The expanded tools", "More of the library, picked per step.")]
            case .pro:
                [("Unlimited AI plans", "A step-by-step plan for every assignment."),
                 ("Unlimited tasks", "However much you are actually carrying."),
                 ("Unlimited rubrics", "However many mark schemes you carry."),
                 ("5 markings a week", "Mark a draft, revise it, mark it again."),
                 ("Every study tool", "The whole library, picked per step.")]
            }
        }
    }

    private var isFlying: Bool { phase == .flight }
    private var showsContent: Bool { phase != .flight }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.page.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    heroPanel
                        .padding(.horizontal, heroInset)
                        .padding(.top, heroTop)

                    if entitlements.refreshFailed {
                        EntitlementRefreshNotice()
                            .padding(.horizontal, heroInset)
                            .padding(.top, 12)
                    }

                    // **The picker comes before the detail.**
                    //
                    // It was the other way round, inherited from a two-plan
                    // screen where the choice was monthly-or-annual and the
                    // pitch above it was the actual content. With three plans
                    // the choice *is* the content — and in that order the cards
                    // landed below the fold, behind the purchase bar, on a
                    // screen whose entire job is comparing three prices. The UI
                    // test passed the whole time: `waitForExistence` is happy
                    // with an element that exists, and those cards existed
                    // perfectly well where nobody could see them.
                    headline.padding(.top, 20)
                    planPicker.padding(.top, 20)
                    // Below the cards, not above: the cards have to clear the
                    // purchase bar on a 667pt phone, and the picker only
                    // changes what they say, not which one to pick.
                    if offersYearly { periodPicker.padding(.top, 12) }
                    valueList.padding(.top, 22)
                }
                .padding(.bottom, 230)
            }
            .scrollDisabled(phase != .done)

            purchaseBar.frame(maxHeight: .infinity, alignment: .bottom)
            closeButton
            if phase != .done { intro }
        }
        .background(Palette.page)
        .task(id: runID) { await runIntro() }
        // Prices that failed to load at launch get another try when the
        // student comes to look at them.
        .task {
            if case .failed = purchases.availability { await purchases.load() }
        }
        .onChange(of: plan) { _, _ in notice = nil }
        .onChange(of: period) { _, _ in notice = nil }
    }

    // MARK: - Intro

    /// Full-bleed scene, then a zoom down into the hero panel's frame.
    ///
    /// One view animating its own inset rather than two views cross-fading, so
    /// the moon and the cactus keep their positions through the transition —
    /// the whole point of the shot is that it is the same scene, arriving.
    private var intro: some View {
        GeometryReader { geo in
            let inset = isFlying
                ? EdgeInsets()
                : EdgeInsets(top: heroTop, leading: heroInset,
                             bottom: geo.size.height - heroTop - heroHeight, trailing: heroInset)

            Palette.night
                .overlay {
                    MoonScene(animated: true, runID: runID)
                        .scaleEffect(isFlying ? 1.95 : 1)
                }
                .clipShape(RoundedCornersShape(top: isFlying ? 0 : arch,
                                               bottom: isFlying ? 0 : 22))
                .padding(inset)
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        // Tapping skips. Someone who has seen it once should not have to sit
        // through it again to reach the price.
        .onTapGesture { finishIntro() }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Skip the introduction")
    }

    private func runIntro() async {
        guard autoplay, !reduceMotion else { phase = .done; return }
        phase = .flight
        try? await Task.sleep(for: .seconds(2.35))
        guard !Task.isCancelled, phase == .flight else { return }
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.95)) { phase = .hero }
        try? await Task.sleep(for: .seconds(1.0))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.4)) { phase = .done }
    }

    private func finishIntro() {
        withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.5)) { phase = .done }
    }

    // MARK: - Content

    /// The scene at rest, sitting in the page. Tapping replays the intro.
    private var heroPanel: some View {
        Palette.night
            .frame(height: heroHeight)
            .frame(maxWidth: .infinity)
            // The scene is authored at a fixed 370x310 and positions every
            // element from its top-left, so it does not reflow — it has to be
            // scaled into a shorter panel rather than clipped by one.
            .overlay {
                MoonScene(animated: false, runID: runID)
                    .scaleEffect(heroHeight / MoonScene.height)
            }
            .clipShape(RoundedCornersShape(top: arch, bottom: 22))
            .contentShape(Rectangle())
            .onTapGesture { runID += 1 }
            .accessibilityLabel("Replay the introduction")
    }

    private var headline: some View {
        (Text("Albus plans.\n") + Text("You").foregroundColor(Palette.violet) + Text(" progress."))
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .kerning(-0.6)
            .lineSpacing(2)
            .foregroundStyle(Palette.ink)
            .padding(.horizontal, heroInset)
            .rise(showsContent, delay: 0.10)
    }

    /// What the selected plan includes.
    ///
    /// The list is bound to the picker rather than sitting above it as a fixed
    /// pitch: the question a student is answering is "what do these three cost
    /// me and give me", and a static list of benefits answers neither half.
    private var valueList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(plan == .free ? "WHAT FREE COVERS" : "WHAT \(plan.title.uppercased()) ADDS")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .tracking(1.5)
                .foregroundStyle(Palette.gray)
                .padding(.horizontal, 2)
                .animation(nil, value: plan)

            VStack(spacing: 8) {
                ForEach(plan.lines, id: \.0) { title, detail in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                        Text(detail)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.gray)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Palette.border, lineWidth: 0.5)
                    }
                }
            }
        }
        .padding(.horizontal, heroInset)
        .rise(showsContent, delay: 0.18)
        .animation(.easeInOut(duration: 0.22), value: plan)
    }

    /// Three cards, cheapest first.
    ///
    /// Free is a card rather than a footnote on purpose. A student on Free is
    /// already using the plan and deserves to see what they have; hiding it
    /// makes the screen a sales page rather than a price list, and makes
    /// "what am I on now" unanswerable from the only screen that knows.
    private var planPicker: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(Plan.allCases) { option in
                let shown = price(of: option)
                PlanCard(plan: option,
                         price: shown.amount,
                         period: shown.period,
                         isSelected: plan == option,
                         isCurrent: current == option) { plan = option }
            }
        }
        .padding(.horizontal, heroInset)
        .rise(showsContent, delay: 0.26)
    }

    /// Monthly or yearly. Two labelled segments rather than a switch: the
    /// choice changes what is billed, and a switch reads as on or off.
    private var periodPicker: some View {
        HStack(spacing: 4) {
            ForEach(PurchaseService.Period.allCases) { option in
                let isSelected = selectedPeriod == option
                Button { period = option } label: {
                    HStack(spacing: 6) {
                        Text(option.title)
                        if option == .yearly, let saving = yearlySaving {
                            Text("Save \(saving)%")
                                .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                .foregroundStyle(isSelected ? Palette.violet : .white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(isSelected ? Color.white : Palette.violet, in: Capsule())
                        }
                    }
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? .white : Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 36)
                    .background(isSelected ? Palette.violet : .clear, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option == .yearly && yearlySaving != nil
                                    ? "\(option.title), save \(yearlySaving ?? 0) percent"
                                    : option.title)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Color(hex: 0xF3F1EC), in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.border, lineWidth: 1) }
        .padding(.horizontal, heroInset)
        .rise(showsContent, delay: 0.30)
    }

    private var purchaseBar: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Palette.page.opacity(0), Palette.page],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 30)

            VStack(spacing: 9) {
                Button(action: purchase) {
                    ZStack {
                        Text(callToAction).opacity(isBusy ? 0 : 1)
                        if isBusy { ProgressView().tint(.white) }
                    }
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(isCurrentPlan ? Color(hex: 0x9CA3AF) : Palette.violet,
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Palette.violet.opacity(isCurrentPlan ? 0 : 0.45),
                            radius: 14, x: 0, y: 10)
                }
                .buttonStyle(.plain)
                .disabled(isCurrentPlan || isBusy)
                .accessibilityLabel(isBusy ? "Working" : callToAction)

                Text(subCaption)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.gray)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let notice {
                    Text(notice)
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.opacity)
                }

                HStack(spacing: 8) {
                    footerLink("Restore", action: restore)
                        .disabled(isBusy)
                    footerDot
                    footerLink("Terms") { openURL(AppLinks.terms) }
                    footerDot
                    footerLink("Privacy") { openURL(AppLinks.privacy) }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: notice)
            .padding(.horizontal, heroInset)
            .padding(.top, 6)
            .padding(.bottom, 24)
            .background(Palette.page)
        }
        .rise(showsContent, delay: 0.34)
        .allowsHitTesting(showsContent)
    }

    /// Which plan the student is on right now, so the screen can say so rather
    /// than offering to sell them what they already have.
    private var current: Plan {
        Plan(rawValue: entitlements.tier.rawValue) ?? .free
    }

    private var isCurrentPlan: Bool { plan == current }

    private var isBusy: Bool { isConfirming || purchases.isWorking }

    /// Yearly is offered only once the App Store has priced it for every paid
    /// plan. A build that cannot buy shows monthly display prices.
    private var offersYearly: Bool {
        Plan.allCases.allSatisfy { $0 == .free || purchases.option($0.tier, .yearly) != nil }
    }

    private var selectedPeriod: PurchaseService.Period { offersYearly ? period : .monthly }

    /// What the button would buy, once the App Store has priced it.
    private var selectedOffer: PurchaseService.Option? {
        plan == .free ? nil : purchases.option(plan.tier, selectedPeriod)
    }

    private var yearlySaving: Int? {
        purchases.yearlySaving(plan == .free ? .plus : plan.tier)
    }

    /// What a card says a plan costs: the App Store's price in this
    /// storefront once it has loaded, and until then, or in a build that
    /// cannot buy, the display copy `PricingTests` pins to the server.
    private func price(of option: Plan) -> (amount: String, period: String) {
        if option != .free, let offer = purchases.option(option.tier, selectedPeriod) {
            return (offer.price, selectedPeriod.unit)
        }
        return (option.price, option.period)
    }

    /// The billed price of the selected plan, as it will be charged.
    private var billed: String {
        let shown = price(of: plan)
        var line = "\(shown.amount) \(shown.period)"
        if selectedPeriod == .yearly, let perWeek = selectedOffer?.pricePerWeek {
            line += " (\(perWeek) a week)"
        }
        return line
    }

    /// Only an offer the App Store says this Apple ID can still take is
    /// called free. Apple gives one trial per subscription group, and a
    /// button that promises a trial the sheet then doesn't show is a
    /// rejection.
    private var callToAction: String {
        if isCurrentPlan { return "Your plan" }
        if plan == .free { return current == .free ? "Free is included" : "Manage subscription" }
        if current == .free {
            if let trial = selectedOffer?.freeTrial { return "Start \(trial) free" }
            return "Subscribe to \(plan.title)"
        }
        return "Switch to \(plan.title)"
    }

    /// The terms under the button. The billed amount is always here in full,
    /// and the trial, when there is one, is described as what comes before it.
    private var subCaption: String {
        if isCurrentPlan {
            return plan == .free
                ? "You're on Free. Pick a plan above to see what it adds."
                : "You're on \(plan.title). Thank you."
        }
        if plan == .free {
            return current == .free
                ? "Free needs no subscription."
                : "Cancel in your Apple subscriptions. \(current.title) stays until the time you paid for runs out."
        }
        if current == .free {
            if let trial = selectedOffer?.freeTrial {
                return "\(trial) free, then \(billed). Renews automatically. Cancel anytime."
            }
            return "\(billed). Renews automatically. Cancel anytime."
        }
        return plan.tier > current.tier
            ? "\(billed). Starts now."
            : "\(billed). Starts at your next renewal."
    }

    private func footerLink(_ label: String, action: @escaping () -> Void) -> some View {
        Button(label, action: action)
            .font(.system(size: 11.5, design: .rounded))
            .foregroundStyle(Palette.gray)
            .underline()
    }

    private var footerDot: some View {
        Circle().fill(Color(hex: 0xCFC8BC)).frame(width: 2.5, height: 2.5)
    }

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Palette.ink)
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.75), in: Circle())
                .overlay { Circle().strokeBorder(Palette.ink.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .padding(.top, 62)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .rise(showsContent, delay: 0.40)
        .accessibilityLabel("Close")
    }

    /// Hands off to the App Store, then waits for the server.
    ///
    /// The plan never comes from the phone: the server hears about the
    /// purchase from RevenueCat and `PurchaseFlow` waits until it says so.
    /// Choosing Free while paying opens Apple's subscription page, which is
    /// the only place a subscription can be cancelled.
    private func purchase() {
        guard !isCurrentPlan, !isBusy else { return }
        notice = nil
        if plan == .free {
            Task { await PurchaseFlow.manageSubscription(purchases: purchases) { openURL($0) } }
            return
        }
        Task {
            isConfirming = true
            defer { isConfirming = false }
            // A load that failed (offline when the screen opened) gets one
            // more try before the student is told anything.
            if selectedOffer == nil, case .failed = purchases.availability {
                await purchases.load()
            }
            guard let offer = selectedOffer else {
                notice = unavailableReason
                return
            }
            switch await PurchaseFlow.buy(offer, purchases: purchases, entitlements: entitlements) {
            case .unlocked: dismiss()
            case .message(let text): notice = text
            case .nothing: break
            }
        }
    }

    private func restore() {
        guard !isBusy else { return }
        notice = nil
        Task {
            isConfirming = true
            defer { isConfirming = false }
            notice = await PurchaseFlow.restore(purchases: purchases, entitlements: entitlements)
        }
    }

    private var unavailableReason: String {
        switch purchases.availability {
        case .failed(let reason): reason
        case .loading: "Still loading prices. Try again in a moment."
        case .unavailable: "Purchases aren't available in this version of Albus."
        case .ready: "That plan isn't on sale right now."
        }
    }

    // MARK: - Plan card

    private struct PlanCard: View {
        let plan: Plan
        let price: String
        let period: String
        let isSelected: Bool
        /// Whether this is the plan the student is already on. Marked rather
        /// than hidden — "you are here" is the most useful thing a price list
        /// can tell somebody who already pays.
        let isCurrent: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(.white)
                            .frame(width: 13, height: 13)
                            .overlay {
                                Circle().strokeBorder(
                                    isSelected ? Palette.violet : Color(hex: 0xCFC8BC),
                                    lineWidth: isSelected ? 4.5 : 1.5)
                            }
                        Text(plan.title)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(Palette.ink)
                            .lineLimit(1)
                    }
                    Text(price)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .padding(.top, 8)
                    Text(period)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.gray)
                        .padding(.top, 1)
                    Text(plan.pitch)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.gray)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 6)
                        .frame(minHeight: 26, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(isSelected ? 11 : 12)
                .background(isSelected ? Color.white : Color(hex: 0xF3F1EC),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(isSelected ? Palette.violet : Palette.border,
                                      lineWidth: isSelected ? 2 : 1)
                }
                .overlay(alignment: .topLeading) {
                    if let tag = isCurrent ? "CURRENT" : plan.tag {
                        Text(tag)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .tracking(0.8)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(isCurrent ? Color(hex: 0x4B5563) : Palette.violet,
                                        in: Capsule())
                            .offset(x: 8, y: -8)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(plan.title), \(price) \(period)"
                + (isCurrent ? ", your current plan" : ""))
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
    }

    // MARK: - Palette
    //
    // Local to this screen and taken from the design rather than from `Tokens`.
    // The paywall is the one surface that is deliberately not the rest of the
    // app: a violet night scene against the app's paper. Mapping it onto the
    // shared palette would quietly redesign it.
    enum Palette {
        static let violet = Color(hex: 0x6D28D9)
        static let ink = Color(hex: 0x111827)
        static let gray = Color(hex: 0x6B7280)
        static let border = Color(hex: 0xE5E7EB)
        static let page = Color(hex: 0xFAF8F3)
        static let night = LinearGradient(
            colors: [Color(hex: 0x1A0F33), Color(hex: 0x2A1657), Color(hex: 0x3B1F73)],
            startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Moon scene

/// The night scene: stars, a rising moon, Albus flying up to it.
///
/// `animated` is the difference between the intro and the panel at rest. At
/// rest everything is in its final position and only the ambient loops run, so
/// the panel never looks like a paused video.
private struct MoonScene: View {
    let animated: Bool
    let runID: Int

    @State private var landed = false
    @State private var twinkle = false
    @State private var bob = false

    /// The scene is authored at exactly this size and every offset below is a
    /// literal from the design. The hero panel is the screen width minus two
    /// 16pt insets, which on the design's device is exactly 370.
    static let width: CGFloat = 370
    static let height: CGFloat = 310

    /// x, y, size, delay — authored wider than the panel so the field still
    /// fills the frame while the scene is scaled up during the flight.
    private static let stars: [(CGFloat, CGFloat, CGFloat, Double)] = [
        (-70, 34, 3, 0), (18, 18, 2, 0.6), (64, 74, 3, 1.2), (118, 30, 2, 0.3), (-24, 118, 2, 0.9),
        (-52, 208, 3, 1.6), (22, 168, 2, 1.1), (148, 96, 2, 0.5), (204, 22, 3, 0.8), (252, 62, 2, 1.4),
        (306, 34, 3, 0.2), (352, 92, 2, 1.0), (398, 40, 3, 0.7), (430, 130, 2, 1.5), (336, 176, 2, 0.4),
        (402, 214, 3, 1.3), (-96, 150, 2, 0.5), (284, 132, 2, 1.7), (86, 226, 2, 0.8), (180, 58, 2, 1.9),
        (244, 196, 3, 0.6), (-8, 264, 2, 1.2),
    ]

    private var w: CGFloat { Self.width }
    private var h: CGFloat { Self.height }

    /// Everything is placed from the top-left, because the design is CSS
    /// `position: absolute; left/top`. `.position()` centres instead, which is
    /// what put the cactus in the corner and lost the badge off-frame.
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            starField.offset(x: -110, y: -60)
            horizonGlow.offset(x: w / 2 - 230, y: h - 96 - 190)
            moon.offset(x: w / 2 - 310, y: h + 122 - 268)
            trail
            floatingCard(rotation: -9, lines: true, delay: 2.42).offset(x: 38, y: 106)
            floatingCard(rotation: 10, lines: false, delay: 2.56).offset(x: w - 34 - 62, y: 116)
            checkBadge.offset(x: 196, y: 28)
            cactus.offset(x: w / 2 - 52, y: h - 140 - 132)
        }
        .frame(width: w, height: h, alignment: .topLeading)
        // Deliberately not clipped here. The moon is 620pt wide and most of it
        // sits below the panel; clipping at the authored size drew a hard seam
        // across the full-bleed intro where the scene ended and the background
        // gradient took over. The hero panel and the intro overlay each clip to
        // their own shape, which is the only clip the design has.
        .onAppear(perform: start)
        .onChange(of: runID) { _, _ in start() }
        .accessibilityHidden(true)
    }

    private func start() {
        // Both drive `repeatForever` animations, so they start only where
        // motion is wanted. They used to start always — including on the
        // settled panel and with Reduce Motion on — so the twinkle and the bob
        // never stopped: perpetual motion for a student who asked the system
        // for none, and an app that never reports itself idle. Every UI
        // interaction on this screen then waited out the automation idle
        // timeout, which is why the paywall could only be checked by hand.
        twinkle = animated
        bob = animated
        guard animated else { landed = true; return }
        landed = false
        withAnimation(.timingCurve(0.3, 0.9, 0.3, 1, duration: 1.06).delay(0.5)) { landed = true }
    }

    private var starField: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(Array(Self.stars.enumerated()), id: \.offset) { index, star in
                let (x, y, size, delay) = star
                Circle()
                    .fill(Color(hex: 0xF3E8FF))
                    .frame(width: size, height: size)
                    .opacity(twinkle ? 0.8 : 0.3)
                    .animation(
                        .easeInOut(duration: 2.6 + Double(index % 4) * 0.5)
                            .repeatForever(autoreverses: true).delay(delay),
                        value: twinkle)
                    .offset(x: x + 110, y: y + 60)
            }
        }
        .frame(width: 590, height: 430, alignment: .topLeading)
    }

    private var horizonGlow: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [Color(hex: 0xA78BFA).opacity(0.55), Color(hex: 0xA78BFA).opacity(0)],
                center: .bottom, startRadius: 0, endRadius: 190))
            .frame(width: 460, height: 190)
    }

    /// A wide, shallow disc whose top edge is the horizon the cactus stands on.
    /// Most of it sits below the panel — only the top ~146pt is ever visible.
    private var moon: some View {
        Ellipse()
            .fill(RadialGradient(
                colors: [Color(hex: 0x9F73F5), Color(hex: 0x7C3AED),
                         Color(hex: 0x5B21B6), Color(hex: 0x45177F)],
                center: UnitPoint(x: 0.5, y: 0), startRadius: 0, endRadius: 340))
            .frame(width: 620, height: 268)
            .overlay {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    crater(96, 52, 74, 26, 0.32)
                    crater(236, 96, 52, 18, 0.26)
                    crater(402, 60, 88, 28, 0.28)
                    Ellipse().fill(.white.opacity(0.14))
                        .frame(width: 34, height: 13).offset(x: 330, y: 30)
                }
                .frame(width: 620, height: 268, alignment: .topLeading)
                .clipShape(Ellipse())
            }
            .shadow(color: Color(hex: 0x8B5CF6).opacity(0.4), radius: 23, x: 0, y: -7)
    }

    private func crater(_ x: CGFloat, _ y: CGFloat, _ cw: CGFloat, _ ch: CGFloat,
                        _ opacity: Double) -> some View {
        Ellipse().fill(Color(hex: 0x45177F).opacity(opacity))
            .frame(width: cw, height: ch).offset(x: x, y: y)
    }

    /// The dots Albus leaves on the way up, each fading as he passes.
    @ViewBuilder private var trail: some View {
        if animated {
            ZStack(alignment: .topLeading) {
                Color.clear
                ForEach(Array([(318.0, 284.0, 5.0), (296, 256, 5), (272, 226, 4),
                               (248, 198, 4), (226, 174, 3), (206, 154, 3)].enumerated()),
                        id: \.offset) { index, dot in
                    Circle()
                        .fill(Color(hex: 0xC4B5FD))
                        .frame(width: dot.2, height: dot.2)
                        .opacity(landed ? 0 : 0.95)
                        .animation(.easeOut(duration: 0.5).delay(0.58 + Double(index) * 0.07),
                                   value: landed)
                        .offset(x: dot.0, y: dot.1)
                }
            }
        }
    }

    private func floatingCard(rotation: Double, lines: Bool, delay: Double) -> some View {
        VStack(alignment: .leading, spacing: lines ? 7 : 9) {
            if lines {
                ForEach(Array([26, 40, 32, 38].enumerated()), id: \.offset) { index, lineWidth in
                    Capsule()
                        .fill(index == 0 ? Color(hex: 0xC4B5FD) : Color(hex: 0xE3E0DA))
                        .frame(width: CGFloat(lineWidth), height: 4)
                }
            } else {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(index < 2 ? PaywallScreen.Palette.violet : Color(hex: 0xE3E0DA))
                            .frame(width: 8, height: 8)
                        Capsule().fill(Color(hex: 0xE3E0DA))
                            .frame(width: index == 2 ? 18 : 26, height: 4)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(width: 62, height: 74, alignment: .topLeading)
        .background(.white.opacity(0.94), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .shadow(color: Color(hex: 0x180A30).opacity(0.6), radius: 13, x: 0, y: 14)
        .rotationEffect(.degrees(rotation))
        .offset(y: bob ? -7 : 0)
        .animation(.easeInOut(duration: lines ? 5 : 5.6).repeatForever(autoreverses: true), value: bob)
        .scaleEffect(landed ? 1 : 0.35)
        .opacity(landed ? 1 : 0)
        .animation(animated ? .spring(response: 0.5, dampingFraction: 0.55).delay(delay) : nil,
                   value: landed)
    }

    private var checkBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 22, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 48, height: 48)
            .background(PaywallScreen.Palette.violet, in: Circle())
            .shadow(color: PaywallScreen.Palette.violet.opacity(0.9), radius: 12, x: 0, y: 12)
            .scaleEffect(landed ? 1 : 0)
            .animation(animated ? .spring(response: 0.55, dampingFraction: 0.5).delay(1.8) : nil,
                       value: landed)
    }

    /// Albus, flying in from the lower right and landing on the moon's horizon.
    private var cactus: some View {
        ZStack(alignment: .bottom) {
            Ellipse().fill(Color(hex: 0x3C146E).opacity(0.34))
                .frame(width: 92, height: 16).blur(radius: 4).offset(y: 2)
            AlbusCactus(size: 104, mood: .calm)
        }
        .frame(width: 104, height: 132, alignment: .bottom)
        .rotationEffect(.degrees(landed ? 0 : -30), anchor: .bottom)
        .scaleEffect(landed ? 1 : 0.62, anchor: .bottom)
        .opacity(animated && !landed ? 0 : 1)
        .offset(x: landed ? 0 : 148, y: landed ? 0 : 296)
    }
}

// MARK: - Support

/// The hero panel's shape: a tall arch on top, a gentle radius at the base.
private struct RoundedCornersShape: Shape {
    var top: CGFloat
    var bottom: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(top, bottom) }
        set { top = newValue.first; bottom = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        // Clamped, because the arch is taller than half the panel at rest and a
        // corner radius larger than the shape produces an inverted path.
        let t = min(top, min(rect.width, rect.height) / 2)
        let b = min(bottom, min(rect.width, rect.height) / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - b))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + t))
        path.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + t),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - b))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - b, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + b, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - b),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private extension View {
    /// The design's `mnUp`: content rises and fades in once the intro clears.
    func rise(_ shown: Bool, delay: Double) -> some View {
        opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : 16)
            .animation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.6).delay(delay), value: shown)
    }
}

// `Color(hex:)` lives in Tokens.swift. This file used to carry its own copy
// because Tokens was in AlbusCore, a different module, so the two could not
// collide. Tokens is in this target now, and two identical inits in one module
// are a redeclaration — so the local copy is gone and the shared one is used.
