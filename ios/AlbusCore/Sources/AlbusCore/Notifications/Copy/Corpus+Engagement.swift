import Foundation

// MARK: - Dormancy, back-off and momentum
//
// The Duolingo half of the taxonomy, with one deliberate difference: there is
// no streak. A streak is a punishment the app invents and then threatens the
// student with. Albus already has real stakes — the deadlines are not made up
// — so momentum here is a number that goes up or down and never something you
// can lose.

extension Corpus {
    static let engagement: [CopyTemplate] = [

        // — dormant, day 3 —
        .init("dorm3.chaos.01", .dormantSoft, nil, .chaos,
              "Still here",
              "I've been standing in the same spot for three days. Cacti are good at that."),
        .init("dorm3.chaos.02", .dormantSoft, nil, .chaos,
              "A few days",
              "{assignment}: due {days} from now. Worth a look."),
        .init("dorm3.chaos.03", .dormantSoft, nil, .chaos,
              "Checking in",
              "Open your plan to see what's next. I'll be here."),
        .init("dorm3.chaos.04", .dormantSoft, nil, .chaos,
              "It's been a minute",
              "{count} assignments still open. I've been keeping them warm."),
        .init("dorm3.chaos.05", .dormantSoft, nil, .chaos,
              "No pressure",
              "Well. Some pressure. {assignment} is {days} out."),
        .init("dorm3.chaos.06", .dormantSoft, nil, .chaos,
              "Hello",
              "It's been a few days since you opened Albus. I remain a cactus."),

        .init("dorm3.plain.01", .dormantSoft, nil, .plain,
              "It's been a few days",
              "{count} assignments are still open."),
        .init("dorm3.plain.02", .dormantSoft, nil, .plain,
              "Your plan is waiting",
              "{assignment} is due in {days}."),

        // — dormant, day 7 —
        .init("dorm7.chaos.01", .dormantFinal, nil, .chaos,
              "Week one of being a houseplant",
              "Your deadlines have been less relaxed about it than I have."),
        .init("dorm7.chaos.02", .dormantFinal, nil, .chaos,
              "A whole week",
              "{assignment} is now {days} away. It was further."),
        .init("dorm7.chaos.03", .dormantFinal, nil, .chaos,
              "About a week",
              "I'm not going anywhere. Open your plan when you're ready."),
        .init("dorm7.chaos.04", .dormantFinal, nil, .chaos,
              "Still {count} open",
              "Review what remains and choose a place to start."),
        .init("dorm7.chaos.05", .dormantFinal, nil, .chaos,
              "Long time",
              "Open your saved plan and review what still fits."),
        .init("dorm7.chaos.06", .dormantFinal, nil, .chaos,
              "About a week",
              "{assignment} in {days}. Open your plan when you can."),

        .init("dorm7.plain.01", .dormantFinal, nil, .plain,
              "A week since you last opened Albus",
              "{count} assignments are still open."),
        .init("dorm7.plain.02", .dormantFinal, nil, .plain,
              "Your plan is still here",
              "{assignment} is due in {days}."),

        // — back-off —
        //
        // Duolingo's most effective notification is the one saying it will stop.
        // The honest version keeps the warnings: reminders pause, deadlines do
        // not, and anything genuinely at risk still gets through.
        .init("off.chaos.01", .backOff, nil, .chaos,
              "These clearly aren't working",
              "Routine nudges are paused. Urgent warnings are still subject to your settings."),
        .init("off.chaos.02", .backOff, nil, .chaos,
              "Taking the hint",
              "Routine nudges are paused for a while. The cactus is taking a breath."),
        .init("off.chaos.03", .backOff, nil, .chaos,
              "Going quiet",
              "Routine nudges are paused for a while. Your plan is still in the app."),
        .init("off.chaos.04", .backOff, nil, .chaos,
              "Enough from me",
              "Routine nudges are paused. Urgent warnings still depend on your settings."),
        .init("off.chaos.05", .backOff, nil, .chaos,
              "Fair enough",
              "I'll be a plant for a bit. Routine nudges are paused."),
        .init("off.chaos.06", .backOff, nil, .chaos,
              "Going quiet for now",
              "Routine nudges are paused for a while. Urgent warnings may still appear."),

        .init("off.plain.01", .backOff, nil, .plain,
              "Pausing routine reminders",
              "Routine reminders are paused. Urgent warnings may still appear."),
        .init("off.plain.02", .backOff, nil, .plain,
              "Going quiet for now",
              "Routine reminders are paused for a while. You can still open your plan."),

        // — momentum —
        .init("mom.chaos.01", .momentum, nil, .chaos,
              "{weekMinutes} recorded",
              "Timer time from your latest seven-day summary. Quietly respectable."),
        .init("mom.chaos.02", .momentum, nil, .chaos,
              "Your latest summary",
              "{weekMinutes} recorded on your timer. I do enjoy a number."),
        .init("mom.chaos.03", .momentum, nil, .chaos,
              "Time recorded",
              "{weekMinutes} in your latest seven-day summary. Just an observation."),
        .init("mom.chaos.04", .momentum, nil, .chaos,
              "Your latest summary",
              "{weekMinutes} on your timer. The record noticed."),
        .init("mom.chaos.05", .momentum, nil, .chaos,
              "For the record",
              "{weekMinutes} in your latest seven-day summary. No judgement."),
        .init("mom.chaos.06", .momentum, nil, .chaos,
              "Tally",
              "{weekMinutes} of recorded timer time. Onwards."),

        .init("mom.plain.01", .momentum, nil, .plain,
              "{weekMinutes} recorded",
              "Timer time from your latest seven-day summary."),
        .init("mom.plain.02", .momentum, nil, .plain,
              "Your latest summary",
              "{weekMinutes} recorded on your timer."),
    ]
}
