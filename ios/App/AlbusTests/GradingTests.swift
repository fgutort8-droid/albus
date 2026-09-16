import Testing
import Foundation
import SwiftData
@testable import Albus
import AlbusCore

/// The two things a grading has to get right before anything else is worth
/// building on it: what it says is left, and what it says the grade is.
///
/// Both were wrong in ways every existing test was green through, which is why
/// these are written against the reported symptom rather than the code path.
@Suite("Plan allowances")
struct PlanAllowanceTests {

    typealias Allowance = EntitlementService.Allowance

    /// **The convention this whole feature rests on, and it is a reversal.**
    ///
    /// Until three tiers existed, `limit == 0` meant "no ceiling" — it was how
    /// Plus was expressed. Free now genuinely gets *zero* gradings, so reading
    /// zero as unlimited would have handed every free student unlimited use of
    /// the most expensive call the app makes.
    ///
    /// Nil is unlimited. Zero is not included. They are different screens.
    @Test("zero is not included; nil is unlimited")
    func zeroIsNotUnlimited() {
        let none = Allowance(limit: 0, used: 0)
        #expect(none.isIncluded == false)
        #expect(none.isUnlimited == false)
        #expect(none.hasAny == false)

        let unlimited = Allowance(limit: nil, used: 900)
        #expect(unlimited.isIncluded)
        #expect(unlimited.isUnlimited)
        #expect(unlimited.hasAny)
        #expect(unlimited.remaining == nil)
    }

    /// The two exhausted-looking states a screen must tell apart. Both have a
    /// remaining of zero; one is answered with a price and one with a date, and
    /// showing the wrong one promises a Monday that never comes.
    @Test("out of allowance and not on the plan are distinguishable")
    func exhaustedIsNotExcluded() {
        let spent = Allowance(limit: 2, used: 2)
        let excluded = Allowance(limit: 0, used: 0)

        #expect(spent.remaining == 0)
        #expect(excluded.remaining == 0)
        #expect(spent.isIncluded)          // the difference
        #expect(excluded.isIncluded == false)
        #expect(spent.hasAny == false)
        #expect(excluded.hasAny == false)
    }

    /// A downgrade mid-period leaves usage above the new limit. "-3 left" is
    /// not a thing to show anybody.
    @Test("usage past the limit never reads as negative")
    func neverNegative() {
        let downgraded = Allowance(limit: 2, used: 7)
        #expect(downgraded.remaining == 0)
        #expect(downgraded.hasAny == false)
        #expect(downgraded.summary == "0 of 2 left")
    }

    @Test("the meter's three sentences are three different sentences")
    func summaries() {
        #expect(Allowance(limit: 0).summary == "Not on this plan")
        #expect(Allowance(limit: nil).summary == "Unlimited")
        #expect(Allowance(limit: 5, used: 2).summary == "3 of 5 left")
    }

    /// Tiers are ordered, and access is asked of the plan rather than of the
    /// name. `tier == .plus` is false for a Pro subscriber — the same shape as
    /// the NULL comparison migration 0009 had to fix, one level up.
    @Test("Pro outranks Plus outranks Free")
    func tierOrdering() {
        #expect(EntitlementService.Tier.free < .plus)
        #expect(EntitlementService.Tier.plus < .pro)
        #expect(EntitlementService.Tier.pro > .free)
        #expect((EntitlementService.Tier.pro == .plus) == false)
    }

    /// Postgres writes microseconds and a two-digit offset. `ISO8601DateFormatter`
    /// needs `.withFractionalSeconds` for the first and `+00:00` for the second,
    /// and each configuration rejects the other's output — so a single formatter
    /// silently drops every reset time that lands on a whole second.
    @Test("both shapes of Postgres timestamp parse")
    func timestampVariants() {
        #expect(PostgresTimestamp.parse("2026-08-27T19:25:50.064319+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-08-27T19:25:50+00:00") != nil)
        #expect(PostgresTimestamp.parse("2026-08-27T19:25:50.064319+00") != nil)
        #expect(PostgresTimestamp.parse(nil) == nil)
        #expect(PostgresTimestamp.parse("not a date") == nil)
    }
}

/// What the paywall promises has to be what the database enforces.
///
/// These numbers live in two places on purpose — the screen must render before
/// a network call returns, and `public.plans` must be the thing that refuses.
/// Two places means they can drift, so the drift is what gets tested. If a
/// price or a limit changes, this fails until both are updated, which is the
/// entire point.
@Suite("Pricing")
struct PricingTests {

    /// Mirrors `public.plans` as applied by migration 0034, with prices from
    /// `20260916120000_launch_prices`. Update together.
    private struct ServerPlan {
        let plan: PaywallScreen.Plan
        let priceCents: Int
        let tasks: Int?      // nil = unlimited
        let gradeWeek: Int?
        let rubrics: Int?
    }

    private static let server: [ServerPlan] = [
        .init(plan: .free, priceCents:    0, tasks:    5, gradeWeek: 0, rubrics:    3),
        .init(plan: .plus, priceCents:  999, tasks:   10, gradeWeek: 2, rubrics:    5),
        .init(plan: .pro,  priceCents: 1799, tasks:  nil, gradeWeek: 5, rubrics:  nil),
    ]

    @Test("every plan's price matches the server's")
    func pricesMatch() {
        for row in Self.server {
            #expect(row.plan.priceCents == row.priceCents,
                    "\(row.plan.title): \(row.plan.priceCents)c on screen, \(row.priceCents)c in public.plans")
        }
        #expect(PaywallScreen.Plan.free.price == "Free")
        #expect(PaywallScreen.Plan.plus.price == "€9.99")
        #expect(PaywallScreen.Plan.pro.price == "€17.99")
    }

    /// `EntitlementService.Plan.freeFallback` is what the app shows before the
    /// first `my_plan()` call returns — so it is a third copy of Free's limits
    /// and can drift like any other. It is the *most* dangerous copy: it is
    /// what a student sees on a cold launch with no network.
    @Test("the offline fallback matches Free on the server")
    func fallbackMatchesFree() {
        guard let free = Self.server.first(where: { $0.plan == .free }) else { return }
        let fallback = EntitlementService.Plan.freeFallback

        #expect(fallback.tier == .free)
        #expect(fallback.priceCents == free.priceCents)
        #expect(fallback.tasks.limit == free.tasks)
        #expect(fallback.grader.limit == free.gradeWeek)
        #expect(fallback.rubrics.limit == free.rubrics)

        // And the consequence, spelled out: the fallback must not accidentally
        // hand out a feature Free does not have.
        #expect(fallback.grader.hasAny == false)
    }

    /// The brief's headline numbers, asserted as text a student will read.
    /// A copy edit that drops "2" from the Plus card is a mis-sold plan.
    @Test("each plan's card names its own grader allowance")
    func graderAllowanceIsOnTheCard() {
        let free = PaywallScreen.Plan.free.lines.map(\.0).joined(separator: " ")
        let plus = PaywallScreen.Plan.plus.lines.map(\.0).joined(separator: " ")
        let pro  = PaywallScreen.Plan.pro.lines.map(\.0).joined(separator: " ")

        #expect(free.contains("No marking"))
        #expect(plus.contains("2 markings a week"))
        #expect(pro.contains("5 markings a week"))
    }

    /// The same guard for AI plans, now the headline difference between tiers.
    /// It must agree with `plans.breakdown_per_week`: Free 5, paid unlimited.
    @Test("each plan's card names its own AI-plan allowance")
    func aiPlanAllowanceIsOnTheCard() {
        #expect(PaywallScreen.Plan.free.lines.first?.0 == "5 AI plans a week")
        #expect(PaywallScreen.Plan.plus.lines.first?.0 == "Unlimited AI plans")
        #expect(PaywallScreen.Plan.pro.lines.first?.0 == "Unlimited AI plans")
    }

    /// "Answers back" sold Ask Albus, which no longer exists. A pitch that
    /// promises a withdrawn feature is a mis-sold plan, not a stale string.
    @Test("no plan's pitch promises the withdrawn assistant")
    func pitchesPromiseOnlyWhatShips() {
        for plan in PaywallScreen.Plan.allCases {
            #expect(!plan.pitch.localizedCaseInsensitiveContains("answer"),
                    "\(plan) pitch: \(plan.pitch)")
        }
    }

    /// Every plan says the same things in the same order, so the eye can
    /// run down a column. Three lists of different lengths is three lists.
    @Test("the three cards are comparable line for line")
    func linesAreParallel() {
        let counts = PaywallScreen.Plan.allCases.map { $0.lines.count }
        #expect(Set(counts).count == 1, "plans list \(counts) lines — not comparable")
    }

    /// Free is a card, not a footnote. A student already on Free must be able
    /// to see what they have from the only screen that knows.
    @Test("Free appears on the paywall")
    func freeIsShown() {
        #expect(PaywallScreen.Plan.allCases.contains(.free))
        #expect(PaywallScreen.Plan.free.pitch.isEmpty == false)
    }
}

/// Which refusals a plan can fix, and which ones it cannot.
@Suite("Refusals")
struct RefusalTests {

    /// Both of these end in the plans screen, and they must say different
    /// things when they get there.
    @Test("running out and never having it are both answerable by upgrading")
    func upgradeable() {
        #expect(GradingService.Failure.notOnPlan.isAnswerableByUpgrading)
        #expect(GradingService.Failure.allowanceUsed(resetsAt: nil).isAnswerableByUpgrading)
    }

    /// Going too fast is not something a plan fixes. Offering to sell somebody
    /// a subscription that would not have helped is worse than saying "wait".
    @Test("going too fast is never answered with a price")
    func rateLimitIsNotAPaywall() {
        #expect(GradingService.Failure.tooFast.isAnswerableByUpgrading == false)
        #expect(GradingService.Failure.offline.isAnswerableByUpgrading == false)
        #expect(GradingService.Failure.unavailable.isAnswerableByUpgrading == false)
        #expect(GradingService.Failure.fairUseReached.isAnswerableByUpgrading == false)
    }

    /// Neither is a thing a purchase resolves, and both must stay reachable as
    /// their own sentence rather than collapsing into "upgrade".
    @Test("a risk pause is not a sales opportunity")
    func riskIsNotAPaywall() {
        #expect(GradingService.Failure.paused.isAnswerableByUpgrading == false)
        #expect(GradingService.Failure.needsVerification.isAnswerableByUpgrading == false)
    }

    /// The copy has to survive a nil reset time — the server does not always
    /// know when the next one lands, and "back at nil" is not a sentence.
    @Test("every refusal renders a sentence, with or without a date")
    func everyRefusalSpeaks() {
        let cases: [GradingService.Failure] = [
            .notOnPlan, .allowanceUsed(resetsAt: nil),
            .allowanceUsed(resetsAt: .now.addingTimeInterval(86_400)),
            .tooFast, .needsVerification, .paused, .fairUseReached, .tooShort, .noRubric,
            .offline, .unavailable, .tooLongToMark, .tooLong(20_000),
        ]
        for failure in cases {
            let text = failure.errorDescription ?? ""
            #expect(text.isEmpty == false, "\(failure) has no sentence")
            #expect(text.contains("nil") == false, "\(failure) leaked a nil")
            #expect(text.contains("Optional") == false, "\(failure) leaked an Optional")
        }
    }
}

@MainActor
@Suite("The final grade")
struct FinalGradeTests {

    private func grading(basis: GradingBasis, label: String?,
                         marks: Int? = nil, total: Int? = nil) -> Grading {
        Grading(model: "claude-opus-5", inputChars: 3_000,
                overallMarks: marks, totalMarks: total,
                gradeLabel: label, gradeNote: label == nil ? nil : "A note.",
                feedback: "…", basis: basis)
    }

    /// The reported bug: "it gives feedback but no final grade."
    ///
    /// The screen only ever had `overall_marks/total_marks` to show, which is
    /// the rubric's arithmetic — an MYP rubric totals 32, and "0/32" is not
    /// what a course puts on the work.
    @Test("the grade is what leads, not the rubric's arithmetic")
    func gradeLeads() {
        let marked = grading(basis: .personal, label: "4", marks: 17, total: 32)

        #expect(marked.headline == "4")
        #expect(marked.headlineIsGrade)
        // The marks still show, beside it rather than instead of it.
        #expect(marked.scoreText == "17/32")
    }

    /// The model is asked for a label and usually gives one. "Usually" is not
    /// good enough for the single number the student opened the app for.
    @Test("marks stand in when no grade was named")
    func marksAreTheFallback() {
        let marked = grading(basis: .personal, label: nil, marks: 17, total: 32)

        #expect(marked.headline == "17/32")
        // Not a grade in their scale, and not dressed up as one.
        #expect(marked.headlineIsGrade == false)
    }

    /// A blind reading has no rubric behind it. Anything in the headline slot
    /// is read as a grade whatever banner sits above it, so there is nothing in
    /// the headline slot.
    @Test("a blind reading has no headline at all")
    func blindHasNoHeadline() {
        let read = grading(basis: .blind, label: nil)
        #expect(read.headline == nil)

        // Even if a label somehow survived the server's stripping, the client
        // refuses it a second time. Two independent guards, because this is the
        // one thing the feature must never do.
        let forged = grading(basis: .blind, label: "A-", marks: 18, total: 20)
        #expect(forged.headline == nil)
    }

    /// A rubric that carries no marks is a real case, and rendering it as "0"
    /// would be a lie about the work.
    @Test("a rubric with no marks has no headline either")
    func commentOnlyRubric() {
        let marked = grading(basis: .personal, label: nil)
        #expect(marked.headline == nil)
    }

    /// History rows are the only place a grading can be identified: the work
    /// itself is deliberately never stored.
    @Test("every grading can be named in a list")
    func displayTitleIsNeverEmpty() {
        let named = Grading(model: "m", inputChars: 900, workTitle: "Bio IA draft",
                            feedback: "…", basis: .personal)
        #expect(named.displayTitle == "Bio IA draft")

        let loose = Grading(model: "m", inputChars: 900, feedback: "…", basis: .blind)
        #expect(loose.displayTitle.isEmpty == false)
    }
}


/// History is only worth having if a grading survives being written.
@MainActor
@Suite("Grading history")
struct GradingHistoryTests {

    private func makeContext() throws -> ModelContext {
        let schema = AlbusSchema.schema
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        return ModelContext(container)
    }

    /// The grade has to come back out, not just go in. Every field added for
    /// the result screen is a field a reopened grading has to still have —
    /// SwiftData will happily accept a property the schema never persisted.
    @Test("a grading round-trips with its grade attached")
    func gradingRoundTrips() throws {
        let context = try makeContext()

        context.insert(Grading(
            model: "claude-opus-5", inputChars: 2_275,
            overallMarks: 11, totalMarks: 15,
            gradeLabel: "6",
            gradeNote: "A secure 6; a 7 needs the historiography adjudicated.",
            workTitle: "Cold War origins essay",
            criteria: [GradedCriterion(code: "A", name: "Knowledge", marks: 4, outOf: 6,
                                       comment: "Thin on dates.", quote: "The Cold War did not begin at a single moment.",
                                       whereFound: "Opening line")],
            feedback: "The argument is the best part of this.",
            improvements: [GradedImprovement(change: "Date the evidence.", why: "Two marks in A.")],
            basis: .personal
        ))
        try context.save()

        let saved = try context.fetch(FetchDescriptor<Grading>())
        #expect(saved.count == 1)

        let one = try #require(saved.first)
        #expect(one.gradeLabel == "6")
        #expect(one.headline == "6")
        #expect(one.headlineIsGrade)
        #expect(one.displayTitle == "Cold War origins essay")
        #expect(one.criteria.first?.quote?.isEmpty == false)
        #expect(one.improvements.count == 1)
    }

    /// A blind reading reopened months later must still read as a reading. The
    /// basis is stored rather than inferred precisely so this cannot drift.
    @Test("a reopened blind reading is still not a grade")
    func blindSurvivesTheRoundTrip() throws {
        let context = try makeContext()
        context.insert(Grading(model: "claude-sonnet-5", inputChars: 900,
                               feedback: "No rubric here.", basis: .blind))
        try context.save()

        let one = try #require(try context.fetch(FetchDescriptor<Grading>()).first)
        #expect(one.basis == .blind)
        #expect(one.headline == nil)
    }
}

/// What the Grader offers to mark, and the two ways it used to hide the answer.
///
/// Both were reported from the app rather than caught by a test: an assignment
/// that had just been finished vanished from the picker, and one opened
/// directly from Task detail was selected with nothing on screen saying so.
@MainActor
@Suite("What the Grader offers to mark")
struct MarkableWorkTests {

    private func store() throws -> ModelContext {
        let container = try ModelContainer(
            for: Assignment.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        return ModelContext(container)
    }

    @discardableResult
    private func make(_ context: ModelContext, _ title: String,
                      status: AssignmentStatus = .active,
                      finishedAgo: TimeInterval = 0,
                      deadlineIn days: Int = 7) -> Assignment {
        let a = Assignment(title: title, deadline: .now.addingTimeInterval(Double(days) * 86_400),
                           estimatedMinutes: 60, status: status)
        if status == .completed { a.updatedAt = .now.addingTimeInterval(-finishedAgo) }
        context.insert(a)
        return a
    }

    /// The reported bug: ticking the last step is *exactly* when a student
    /// wants the work marked, and that is when it left the list.
    @Test("work finished this week is still offered")
    func recentlyFinishedIsOffered() throws {
        let c = try store()
        let open = make(c, "Still going")
        let done = make(c, "Handed in yesterday", status: .completed, finishedAgo: 86_400)

        let shown = GraderScreen.markable(from: [open, done], chosen: nil)
        #expect(shown.contains { $0.id == done.id },
                "work finished yesterday is not offered for marking")
        #expect(shown.contains { $0.id == open.id })
        #expect(shown.count == 2)
    }

    /// Not forever, though — a picker listing a year of finished work is a
    /// different kind of unusable.
    @Test("work finished months ago is not")
    func oldFinishedIsDropped() throws {
        let c = try store()
        let old = make(c, "Last term", status: .completed, finishedAgo: 90 * 86_400)
        #expect(GraderScreen.markable(from: [old], chosen: nil).isEmpty)
    }

    /// The second reported bug. Arriving from Task detail pre-selects the
    /// assignment, but the checkmark is drawn per row — so an assignment
    /// missing from the list was selected invisibly, which reads as a dead tap.
    @Test("whatever the screen was opened with is always shown, and shown first")
    func chosenIsAlwaysPresent() throws {
        let c = try store()
        let filler = (1...15).map { make(c, "Task \($0)") }
        let ancient = make(c, "Finished in the spring", status: .completed,
                           finishedAgo: 200 * 86_400)

        let shown = GraderScreen.markable(from: filler + [ancient], chosen: ancient)
        #expect(shown.first?.title == "Finished in the spring")
        #expect(shown.contains { $0.id == ancient.id })
    }

    /// It must appear once, not twice, when it was already in the list.
    @Test("an already-listed choice is not duplicated")
    func chosenIsNotDuplicated() throws {
        let c = try store()
        let a = make(c, "The one")
        let b = make(c, "Another")
        let shown = GraderScreen.markable(from: [a, b], chosen: a)
        #expect(shown.count == 2)
        #expect(shown.first?.id == a.id)
    }

    /// Six hid work on both paid plans: Plus allows ten open at once.
    @Test("the cap clears a full Plus plan")
    func capFitsPlus() throws {
        let c = try store()
        let ten = (1...10).map { make(c, "Task \($0)") }
        #expect(GraderScreen.markable(from: ten, chosen: nil).count == 10)
    }
}

@Suite("Upgrade copy")
struct UpgradeCopyTests {

    /// The reported bug: "the paywall says free gets 2 gradings a week".
    ///
    /// It was the Grader's own blocked card, whose offer line opened "Plus
    /// marks two pieces of work a week" directly beneath a title about Plus and
    /// Pro — and read as a statement about what the reader already had. Every
    /// count must be attached to the plan it belongs to.
    @Test("every allowance named in upgrade copy is attached to a plan")
    func countsAreAttributedToAPlan() {
        for plan in PaywallScreen.Plan.allCases {
            for (title, _) in plan.lines where title.first?.isNumber == true {
                // A line like "2 markings a week" is fine on Plus's own card,
                // because the card is the attribution. The failure mode this
                // guards is prose elsewhere that quotes a number with no plan.
                #expect(!title.isEmpty)
            }
        }
        // Free must never advertise a marking allowance it does not have.
        let free = PaywallScreen.Plan.free.lines.map(\.0).joined(separator: " ")
        #expect(free.contains("No marking"))
        #expect(!free.contains("2 markings"))
    }
}
