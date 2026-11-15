import Foundation

/// Everything Albus can say, as data.
///
/// Swift arrays rather than a bundled JSON or plist: `AlbusCore` ships no
/// resources today and adding a bundle changes how the package builds, while an
/// array is compile-checked, greppable, and — the reason that actually matters
/// — exhaustively iterable, so a test can prove every reachable cell has
/// something to say and that no joke has leaked into the overdue pool.
///
/// **House rules for anyone adding a line.**
/// - Title at most 40 characters, body at most 110. A truncated punchline is
///   not a punchline.
/// - No exclamation marks. Albus is deadpan; enthusiasm is the other app.
/// - The joke is on Albus or on the situation. Never on the student.
/// - Bold exactly one thing, and make it the thing to do next.
/// - Every `(kind, register)` needs at least two lines with no placeholders, so
///   a moment with thin data can still speak.
public enum Corpus {
    public static let all: [CopyTemplate] =
        brief + nudge + deadline + handIn + overdue + unfit + engagement + quiet
}

// MARK: - Morning brief

extension Corpus {
    static let brief: [CopyTemplate] = [

        // — chaos, calm —
        .init("brief.calm.01", .morningBrief, .calm, .chaos,
              "Suspiciously quiet",
              "Nothing urgent today. I don't trust it either."),
        .init("brief.calm.02", .morningBrief, .calm, .chaos,
              "I checked twice",
              "{minutes} booked. That is genuinely all of it."),
        .init("brief.calm.03", .morningBrief, .calm, .chaos,
              "A light one",
              "{assignment} in {days}. I've seen worse. I've been worse."),
        .init("brief.calm.04", .morningBrief, .calm, .chaos,
              "Morning",
              "Today wants {minutes}. Do it early and I'll leave you alone."),
        .init("brief.calm.05", .morningBrief, .calm, .chaos,
              "Slow day",
              "**{step}** and then nothing. Suspicious, but I'll allow it."),
        .init("brief.calm.06", .morningBrief, .calm, .chaos,
              "Nothing on fire",
              "This is the part where you get ahead. Or don't. I'm a plant."),

        // — chaos, busy —
        .init("brief.busy.01", .morningBrief, .busy, .chaos,
              "Today has shape",
              "{minutes} across {steps}. **{step}** first."),
        .init("brief.busy.02", .morningBrief, .busy, .chaos,
              "A real day",
              "**{step}** is the one that makes the rest shorter. Start there."),
        .init("brief.busy.03", .morningBrief, .busy, .chaos,
              "Morning",
              "{steps} today. I've arranged them. You're welcome."),
        .init("brief.busy.04", .morningBrief, .busy, .chaos,
              "Booked up",
              "{minutes}. {assignment} is due in {days} and knows it."),
        .init("brief.busy.05", .morningBrief, .busy, .chaos,
              "Here's today",
              "**{step}**, then the rest. In that order, ideally."),
        .init("brief.busy.06", .morningBrief, .busy, .chaos,
              "Reasonably full",
              "{minutes} of work. Survivable. Probably."),

        // — chaos, cooked —
        .init("brief.cooked.01", .morningBrief, .cooked, .chaos,
              "Today is a lot",
              "{minutes}. Today also has minutes. Barely enough of them."),
        .init("brief.cooked.02", .morningBrief, .cooked, .chaos,
              "Deep breath",
              "{steps}. Start with **{step}** and don't look at the rest."),
        .init("brief.cooked.03", .morningBrief, .cooked, .chaos,
              "It's a big one",
              "{minutes} today. I'd wish you luck but I've seen the plan."),
        .init("brief.cooked.04", .morningBrief, .cooked, .chaos,
              "Bristling",
              "My spikes are out. That's about you, not me. **{step}** first."),
        .init("brief.cooked.05", .morningBrief, .cooked, .chaos,
              "Heavy",
              "{assignment} is {days} out and today owes it {minutes}."),
        .init("brief.cooked.06", .morningBrief, .cooked, .chaos,
              "Brace",
              "One step at a time is not advice today, it's the only option."),

        // — plain, all workloads —
        .init("brief.plain.01", .morningBrief, nil, .plain,
              "Today's plan",
              "{minutes} across {steps}."),
        .init("brief.plain.02", .morningBrief, nil, .plain,
              "Today's plan",
              "**{step}** is first. {minutes} booked in total."),
        .init("brief.plain.03", .morningBrief, nil, .plain,
              "Today's plan",
              "{assignment} is due in {days}. {steps} scheduled today."),
        .init("brief.plain.04", .morningBrief, nil, .plain,
              "Today's plan",
              "Nothing is overdue. {minutes} scheduled."),
    ]
}

// MARK: - Next block

extension Corpus {
    static let nudge: [CopyTemplate] = [

        // — chaos, calm —
        .init("nudge.calm.01", .windowNudge, .calm, .chaos,
              "Your {minutes}",
              "**{step}**. I'll be here. I'm always here. I'm a cactus."),
        .init("nudge.calm.02", .windowNudge, .calm, .chaos,
              "Starting now",
              "**{step}**, {minutes}, and then your evening is yours."),
        .init("nudge.calm.03", .windowNudge, .calm, .chaos,
              "Small one",
              "{minutes} on **{step}**. Barely counts as work."),
        .init("nudge.calm.04", .windowNudge, .calm, .chaos,
              "It's time",
              "**{step}**. Short. Painless. Allegedly."),

        // — chaos, busy —
        .init("nudge.busy.01", .windowNudge, .busy, .chaos,
              "Go",
              "**{step}**. {minutes}. I'll wait."),
        .init("nudge.busy.02", .windowNudge, .busy, .chaos,
              "Study time",
              "**{step}** for {minutes}. Do it now and tomorrow is short."),
        .init("nudge.busy.03", .windowNudge, .busy, .chaos,
              "This one",
              "**{step}**. {assignment} stops being a problem one step at a time."),
        .init("nudge.busy.04", .windowNudge, .busy, .chaos,
              "Now would be good",
              "{minutes} on **{step}**. The plan says so. I wrote the plan."),

        // — chaos, cooked —
        .init("nudge.cooked.01", .windowNudge, .cooked, .chaos,
              "Pick one. This one.",
              "**{step}**. Everything else needs it done first."),
        .init("nudge.cooked.02", .windowNudge, .cooked, .chaos,
              "Start anywhere. Start here.",
              "**{step}**, {minutes}. Don't read the rest of the plan."),
        .init("nudge.cooked.03", .windowNudge, .cooked, .chaos,
              "No thinking, just this",
              "**{step}**. {minutes}. Go."),
        .init("nudge.cooked.04", .windowNudge, .cooked, .chaos,
              "One thing",
              "**{step}**. That's the whole ask right now."),

        // — plain —
        .init("nudge.plain.01", .windowNudge, nil, .plain,
              "Next: {step}",
              "{minutes}, starting now."),
        .init("nudge.plain.02", .windowNudge, nil, .plain,
              "Time to start",
              "**{step}** — {minutes} on {assignment}."),
        .init("nudge.plain.03", .windowNudge, nil, .plain,
              "Your next block",
              "**{step}**, {minutes}."),
    ]
}
