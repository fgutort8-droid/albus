import Foundation

// MARK: - Quiet-app reminders that need no facts
//
// The plain quiet-app lines all quoted something: how many assignments are
// open, or one that is due and in how many days. Neither is always there to
// quote. A count of one is not offered, because the lines that use it are
// plurals, and an assignment is named only when it is due a day or more after
// the reminder. With one assignment open and due by then, a student who had
// chosen plain reminders would have heard nothing at all.

extension Corpus {
    static let quiet: [CopyTemplate] = [
        .init("dorm3.plain.03", .dormantSoft, nil, .plain,
              "It's been a few days",
              "Open Albus to see what's next in your plan."),
        .init("dorm7.plain.03", .dormantFinal, nil, .plain,
              "A week since you last opened Albus",
              "Open Albus to see what's next in your plan."),
    ]
}
