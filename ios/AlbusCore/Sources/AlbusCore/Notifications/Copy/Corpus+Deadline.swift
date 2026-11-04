import Foundation

// MARK: - Deadline tiers

extension Corpus {
    static let deadline: [CopyTemplate] = [

        // — T-72h, chaos —
        .init("d72.chaos.01", .deadline72, nil, .chaos,
              "{assignment}",
              "The deadline is coming up. I remain rooted to the spot."),
        .init("d72.chaos.02", .deadline72, nil, .chaos,
              "{assignment} — {days}",
              "{steps} left. Pick a place to start."),
        .init("d72.chaos.03", .deadline72, nil, .chaos,
              "Gentle reminder",
              "{assignment} is in {days} and {minutes} of work deep."),
        .init("d72.chaos.04", .deadline72, nil, .chaos,
              "{assignment}",
              "**{step}** is next. I am providing moral support. Quietly."),
        .init("d72.chaos.05", .deadline72, nil, .chaos,
              "Deadline coming up",
              "{assignment}. {steps} left. Worth a look."),
        .init("d72.chaos.06", .deadline72, nil, .chaos,
              "Looking ahead",
              "{assignment} in {days}. I'm mentioning it, not nagging."),

        // — T-72h, plain —
        .init("d72.plain.01", .deadline72, nil, .plain,
              "{assignment} — {days}",
              "{steps} left, about {minutes} of work."),
        .init("d72.plain.02", .deadline72, nil, .plain,
              "Due in {days}",
              "{assignment}. **{step}** is next."),

        // — T-24h, chaos —
        .init("d24.chaos.01", .deadline24, nil, .chaos,
              "{assignment} — due soon",
              "{steps} left. Time to review what remains."),
        .init("d24.chaos.02", .deadline24, nil, .chaos,
              "Due soon",
              "{assignment}, about {minutes} of work left. Start with one step."),
        .init("d24.chaos.03", .deadline24, nil, .chaos,
              "This is the one",
              "{assignment} is due soon. **{step}** is where you start."),
        .init("d24.chaos.04", .deadline24, nil, .chaos,
              "Deadline reminder",
              "{assignment}. Open your plan and review what remains."),
        .init("d24.chaos.05", .deadline24, nil, .chaos,
              "{assignment}",
              "Due soon. {steps} left. I believe in starting somewhere."),
        .init("d24.chaos.06", .deadline24, nil, .chaos,
              "Due soon",
              "{assignment}. Worth checking before you call it a day."),

        // — T-24h, plain —
        .init("d24.plain.01", .deadline24, nil, .plain,
              "{assignment} — due soon",
              "{steps} left, about {minutes}."),
        .init("d24.plain.02", .deadline24, nil, .plain,
              "Due soon",
              "{assignment}. **{step}** is next."),

        // — T-3h, chaos —
        .init("d03.chaos.01", .deadline03, nil, .chaos,
              "{assignment} — {hours}",
              "{steps} left. This is the sprint."),
        .init("d03.chaos.02", .deadline03, nil, .chaos,
              "Deadline approaching",
              "{assignment}. Review what is finished before you hand it in."),
        .init("d03.chaos.03", .deadline03, nil, .chaos,
              "Final stretch",
              "{assignment} in {hours}. **{step}**. Nothing else."),
        .init("d03.chaos.04", .deadline03, nil, .chaos,
              "{hours} left",
              "{assignment}. I'd panic but I'm structurally incapable."),
        .init("d03.chaos.05", .deadline03, nil, .chaos,
              "Deadline approaching",
              "{assignment}, {hours}. Finish something rather than starting everything."),
        .init("d03.chaos.06", .deadline03, nil, .chaos,
              "Clock's going",
              "{assignment} in {hours}. Good enough and handed in beats perfect and late."),

        // — T-3h, plain —
        .init("d03.plain.01", .deadline03, nil, .plain,
              "{assignment} — {hours} left",
              "{steps} remaining."),
        .init("d03.plain.02", .deadline03, nil, .plain,
              "Due in {hours}",
              "{assignment}. **{step}** is next."),
    ]
}

// MARK: - Due today

extension Corpus {
    static let handIn: [CopyTemplate] = [
        .init("today.chaos.01", .handInToday, nil, .chaos,
              "Today",
              "{assignment}. It's today. That's the whole notification."),
        .init("today.chaos.02", .handInToday, nil, .chaos,
              "{assignment} — today",
              "{steps} between you and done."),
        .init("today.chaos.03", .handInToday, nil, .chaos,
              "Due today",
              "{assignment}. **{step}** is next. Check what remains before handing it in."),
        .init("today.chaos.04", .handInToday, nil, .chaos,
              "It's the day",
              "{assignment} is due today. {minutes} of work left."),
        .init("today.chaos.05", .handInToday, nil, .chaos,
              "Today's the deadline",
              "{assignment}. Finish it and I'll stop talking about it."),
        .init("today.chaos.06", .handInToday, nil, .chaos,
              "Hand-in day",
              "{assignment}. Whatever's left, do it now rather than at 23:58."),

        .init("today.plain.01", .handInToday, nil, .plain,
              "{assignment} — due today",
              "{steps} left, about {minutes}."),
        .init("today.plain.02", .handInToday, nil, .plain,
              "Due today",
              "{assignment}. **{step}** is next."),
    ]
}

// MARK: - Overdue
//
// `.plain` only, and enforced by `NotificationKind.allowsChaos` rather than by
// asking authors to remember. There is nothing funny about work a student has
// already missed, and a mascot making a joke here would be the moment they
// delete the app.

extension Corpus {
    static let overdue: [CopyTemplate] = [
        .init("late.plain.01", .overdue, nil, .plain,
              "{assignment} was due {lateBy}",
              "What do you want to do about it?"),
        .init("late.plain.02", .overdue, nil, .plain,
              "{assignment} is overdue",
              "{steps} are still open. You can still finish it."),
        .init("late.plain.03", .overdue, nil, .plain,
              "Missed: {assignment}",
              "Open it and review the remaining steps."),
        .init("late.plain.04", .overdue, nil, .plain,
              "{assignment} — {lateBy} late",
              "Review your remaining steps and available study time."),
        .init("late.plain.05", .overdue, nil, .plain,
              "Overdue",
              "{assignment}. Open it to review what remains."),
        .init("late.plain.06", .overdue, nil, .plain,
              "{assignment}",
              "The deadline has passed. Review the steps or mark finished work done."),
    ]
}

// MARK: - The plan stopped fitting
//
// The one notification no other study app can send, because it needs a
// scheduler that knows what will not fit rather than a list that does not.

extension Corpus {
    static let unfit: [CopyTemplate] = [
        .init("unfit.chaos.01", .planStoppedFitting, nil, .chaos,
              "The plan stopped fitting",
              "{count} steps have nowhere to go before their deadline."),
        .init("unfit.chaos.02", .planStoppedFitting, nil, .chaos,
              "Your plan changed",
              "{count} steps could not be scheduled. Worth another look."),
        .init("unfit.chaos.03", .planStoppedFitting, nil, .chaos,
              "{assignment} doesn't fit",
              "{minutes} of work left. Some steps have no room in the plan."),
        .init("unfit.chaos.04", .planStoppedFitting, nil, .chaos,
              "This won't fit",
              "{assignment}. Review the steps and your available study time."),
        .init("unfit.chaos.05", .planStoppedFitting, nil, .chaos,
              "Bad news, mathematically",
              "{count} steps can't be placed before they're due. Worth a look."),
        .init("unfit.chaos.06", .planStoppedFitting, nil, .chaos,
              "Out of room",
              "{assignment} has unscheduled steps. Review the plan."),

        .init("unfit.plain.01", .planStoppedFitting, nil, .plain,
              "Your plan no longer fits",
              "{count} steps can't be scheduled before their deadline."),
        .init("unfit.plain.02", .planStoppedFitting, nil, .plain,
              "{assignment} doesn't fit",
              "About {minutes} of work remains. Some steps could not be scheduled."),
    ]
}
