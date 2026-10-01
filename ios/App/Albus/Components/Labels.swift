import SwiftUI
import AlbusCore

// Text furniture: the small labelled bits that repeat on nearly every card.
// Each one exists because it appeared three or more times across the design
// sources with identical treatment.

/// The dot that separates meta items. Tiny, but it is drawn a dozen times and
/// a 3pt-vs-4pt drift between screens is exactly the kind of thing nobody
/// notices individually and everybody feels collectively.
struct MetaDot: View {
    var body: some View {
        Circle()
            .fill(Tokens.Palette.separator)
            .frame(width: 3, height: 3)
            .accessibilityHidden(true)
    }
}

/// `HIST 204 · TERM PAPER` — the course code in its subject colour, then the
/// kind of work in grey.
struct CourseTag: View {
    let code: String
    var kind: String?
    let subject: Tokens.SubjectColor

    var body: some View {
        HStack(spacing: Tokens.Spacing.s - 1) {
            Text(code.uppercased())
                .font(Tokens.Typography.overline)
                .tracking(Tokens.Tracking.overline)
                .foregroundStyle(subject.color)
            if let kind {
                MetaDot()
                Text(kind.uppercased())
                    .font(Tokens.Typography.caption)
                    .tracking(0.5)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }
}

/// `Due Fri, May 23` or `Overdue · Fri, May 23`.
///
/// Takes a `Date` and decides lateness itself against an injected `now`, so the
/// overdue styling can be tested without waiting for a deadline to pass.
struct DeadlineLabel: View {
    let deadline: Date
    var now: Date = .now
    /// Extra context after the date, e.g. "tomorrow · 11:59 PM".
    var note: String?

    private var isOverdue: Bool { deadline < now }

    private var tint: Color {
        isOverdue ? Tokens.Palette.danger : Tokens.Palette.inkMuted
    }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs + 2) {
            Image(systemName: "calendar")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(isOverdue ? "Overdue · \(formatted)" : "Due \(formatted)")
                .font(Tokens.Typography.caption)
                .fontWeight(isOverdue ? .semibold : .regular)
                .foregroundStyle(tint)
            if let note, !isOverdue {
                Text("· \(note)")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }
        }
        .lineLimit(1)
        .accessibilityElement(children: .combine)
    }

    private var formatted: String {
        deadline.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

/// `ALBUS'S PLAN            7 steps · 4h 45m` — an uppercase section label with
/// an optional count pill and an optional trailing detail. An empty label
/// leaves the count alone, for a section something else on screen already
/// names.
struct SectionHeader<Trailing: View>: View {
    let label: String
    var count: Int?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            // Only the title and count are combined. Combining the whole row
            // swallows whatever `trailing` is — and once that became a Menu, it
            // took the button out of VoiceOver's reach and folded its label into
            // the heading. A header must stay a header; a control must stay a
            // control.
            HStack(spacing: Tokens.Spacing.s) {
                if !label.isEmpty {
                    Text(label.uppercased())
                        .font(Tokens.Typography.label)
                        .fontWeight(.semibold)
                        .tracking(Tokens.Tracking.sectionHeader)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                }

                if let count {
                    Text("\(count)")
                        .font(Tokens.Typography.overline)
                        .foregroundStyle(Tokens.Palette.accent)
                        .padding(.horizontal, Tokens.Spacing.s)
                        .padding(.vertical, 2)
                        .background(Tokens.Palette.accentWash, in: Capsule())
                        .accessibilityLabel("\(count) items")
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer(minLength: Tokens.Spacing.s)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ label: String, count: Int? = nil) {
        self.init(label: label, count: count) { EmptyView() }
    }
}

/// Formats a duration the way every screen in the design does: `45m`, `2h`,
/// `1h 50m`. Lives here because four components render durations and three
/// different roundings would be three different bugs.
enum DurationText {
    static func short(minutes: Int) -> String {
        let m = max(0, minutes)
        guard m >= 60 else { return "\(m)m" }
        let hours = m / 60, mins = m % 60
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }
}

#Preview("Labels") {
    ZStack {
        BackgroundGradient()
        VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
            CourseTag(code: "HIST 204", kind: "Term Paper", subject: .red)
            CourseTag(code: "STAT 110", kind: "Problem Set", subject: .amber)
            CourseTag(code: "ENGL 188", subject: .violet)

            DeadlineLabel(deadline: .now.addingTimeInterval(86_400), note: "tomorrow · 11:59 PM")
            DeadlineLabel(deadline: .now.addingTimeInterval(-86_400))

            SectionHeader("Albus's plan", count: 7)
            SectionHeader(label: "Due this week", count: 3) {
                Text("7 steps · \(DurationText.short(minutes: 285))")
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Palette.inkMuted)
            }

            Text([15, 45, 60, 110, 285].map { DurationText.short(minutes: $0) }.joined(separator: " · "))
                .font(Tokens.Typography.mono)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
        .padding(Tokens.Spacing.xl)
    }
}
