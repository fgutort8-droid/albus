import SwiftUI
import AlbusCore

// Problems and empties, as one system with three weights.
//
// Every problem used to be the same tinted strip — red, amber or a pulsing
// sparkle — stacked at the top of whatever screen it happened on, so a lost
// save and a weekly allowance looked alike and the student could not tell
// which mattered. Now a problem is only as loud as what it costs:
//
// - `QuietLine`: Albus worked around it and nothing is lost. Secondary text
//   inside the thing it is about.
// - `ProblemCard`: something did not go through and the student can fix it.
//   A title saying what did not happen, a sentence saying what is safe, and
//   the button that does the fix.
// - A whole screen, built by the flow itself (the grader's failed marking):
//   the end of a flow failed, and it shows what was kept.
//
// Red is never a fill: only the small mark beside an inline failure.

/// What a screen shows when it has nothing to show.
///
/// Left-aligned words rather than an icon in a pale circle over centred
/// text — that layout is the one every generated app reaches for. The action
/// is optional because some empties are good news ("nothing overdue") and
/// offering a button there invents work.
struct EmptyState: View {
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.s) {
            Text(title)
                .font(Tokens.Typography.title)
                .tracking(Tokens.Tracking.display)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(Tokens.Typography.body)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle, let action {
                PrimaryButton(title: actionTitle, action: action)
                    .padding(.top, Tokens.Spacing.m)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Spacing.l)
        .accessibilityElement(children: .contain)
    }
}

/// A list or filter with nothing in it: one line, not a whole empty screen.
///
/// The action is a link inside the sentence rather than a button beside it:
/// a 44-point button on a 13-point line pushed the two lines apart, and an
/// inline link is the one place a smaller tap target is the right call.
struct EmptyLine: View {
    let title: String
    var message: String?
    /// A tick for good news, such as nothing overdue.
    var isGoodNews = false
    var actionTitle: String?
    var action: (() -> Void)?

    /// Never opened: the link only carries the tap to `action`.
    private static let actionURL = URL(string: "albus-action:empty-line")!

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            if isGoodNews {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Tokens.Tint.green.foreground)
                    .frame(width: 14)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(title)
                    .font(Tokens.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.Palette.ink)
                if let line = detail {
                    Text(line)
                        .font(Tokens.Typography.label)
                        .fontWeight(.regular)
                        .foregroundStyle(Tokens.Palette.inkSecondary)
                        .tint(Tokens.Palette.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .environment(\.openURL, OpenURLAction { _ in
                            action?()
                            return .handled
                        })
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, Tokens.Spacing.s)
        .accessibilityElement(children: .contain)
    }

    private var detail: AttributedString? {
        var line = AttributedString(message ?? "")
        if let actionTitle, action != nil {
            var link = AttributedString(actionTitle)
            link.link = Self.actionURL
            link.inlinePresentationIntent = .stronglyEmphasized
            if !line.characters.isEmpty { line.append(AttributedString(" ")) }
            line.append(link)
        }
        return line.characters.isEmpty ? nil : line
    }
}

/// Something the student did or asked for did not go through, and they can
/// fix it.
///
/// No icon and no red: on Home the Albus already at the top of the screen
/// turns worried instead, so there is never a second, sadder cactus beside
/// him. The title says what did not happen; the message says what is safe.
struct ProblemCard<Actions: View>: View {
    let title: String
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m + 2) {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Text(title)
                    .font(Tokens.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.Palette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(Tokens.Typography.label)
                    .fontWeight(.regular)
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)

            if Actions.self != EmptyView.self {
                HStack(spacing: Tokens.Spacing.s) { actions() }
            }
        }
        .padding(Tokens.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Palette.cardSurface,
                    in: RoundedRectangle(cornerRadius: Tokens.Radius.problemCard, style: .continuous))
        .shadow(color: Tokens.Glass.shadow.opacity(0.5), radius: 12, y: 6)
        .accessibilityElement(children: .contain)
        // Moved out of a banner at the top and into the flow, so a student
        // using VoiceOver would otherwise never learn it appeared.
        .onAppear { AccessibilityNotification.Announcement(title).post() }
    }
}

extension ProblemCard where Actions == EmptyView {
    init(title: String, message: String) {
        self.init(title: title, message: message) { EmptyView() }
    }
}

/// The buttons inside a `ProblemCard`: a pill, worded as the fix.
struct CardButton: View {
    enum Style { case primary, secondary }

    let title: String
    var style: Style = .primary
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Tokens.Typography.label)
                .fontWeight(.semibold)
                .foregroundStyle(style == .primary ? .white : Tokens.Palette.ink)
                .padding(.horizontal, Tokens.Spacing.xl)
                .frame(minHeight: 44)
                .background {
                    if style == .primary {
                        Capsule().fill(isEnabled ? Tokens.Palette.accent
                                                 : Tokens.Palette.inkMuted.opacity(0.4))
                    } else {
                        Capsule().strokeBorder(Tokens.Palette.ink, lineWidth: 1)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

/// Albus worked around something and nothing is lost: offline, the week's AI
/// plans used, figures not refreshed. Secondary text inside the thing it is
/// about, never a strip at the top of the screen.
struct QuietLine: View {
    let text: String
    var systemImage: String?
    var linkTitle: String?
    var link: (() -> Void)?

    var body: some View {
        HStack(alignment: .center, spacing: Tokens.Spacing.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.Palette.inkSecondary)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let linkTitle, let link {
                Button(linkTitle, action: link)
                    .font(Tokens.Typography.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(Tokens.Palette.accent)
                    .buttonStyle(.plain)
                    .frame(minHeight: 44)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// A failure that belongs to the control just above it: a sign-in that did
/// not go through, a tap that did not reach the server. The mark is the only
/// red; the words stay in ink, where they are easiest to read.
struct ProblemLine: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Tokens.Tint.red.foreground)
                .accessibilityHidden(true)
            Text(message)
                .font(Tokens.Typography.label)
                .fontWeight(.regular)
                .foregroundStyle(Tokens.Palette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .onAppear { AccessibilityNotification.Announcement(message).post() }
    }
}

/// Albus is doing something that takes a moment, such as reading a photo.
struct WorkingLine: View {
    let text: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.s) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Albus's own line about the plan — the mascot slot plus a sentence.
///
/// The slot held a placeholder SF Symbol leaf, with a note here saying it would
/// stand in "until the real cactus asset is added". The cactus arrived as pure
/// geometry that needs no asset, and this was never updated — so every line
/// Albus spoke in the app was signed by a generic leaf.
struct AlbusNote: View {
    let text: AttributedString
    var isBusy: Bool = false

    init(_ text: String, isBusy: Bool = false) {
        self.text = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        self.isBusy = isBusy
    }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Spacing.m) {
            // `isBusy` is the caller saying "this line is about work in
            // progress", which is the same distinction the mascot draws
            // between a calm week and a full one.
            AlbusCactus(size: 30, mood: isBusy ? .busy : .calm)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)

            Text(text)
                .font(Tokens.Typography.caption)
                .foregroundStyle(Tokens.Palette.inkSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("States") {
    ZStack {
        BackgroundGradient()
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                ProblemCard(title: "Your last change didn't save",
                            message: "It's on screen but not stored on this phone yet. If Albus closes now, it's lost.") {
                    CardButton(title: "Save again") {}
                }
                ProblemCard(title: "2 steps don't fit before Monday",
                            message: "There isn't enough of your study time before then.") {
                    CardButton(title: "Change study hours") {}
                    CardButton(title: "Not now", style: .secondary) {}
                }
                QuietLine(text: "Planned on this phone while you were offline, as four study sessions.",
                          systemImage: "wifi.slash")
                QuietLine(text: "This week's AI plans are used, so Albus split it into sessions.",
                          linkTitle: "See Plus") {}
                ProblemLine(message: "Didn't go through. You're offline.")
                WorkingLine(text: "Reading it…")
                AlbusNote("Research is behind you. **Build the outline** is the step that makes tomorrow's draft short.", isBusy: true)
                EmptyState(title: "Your week is open",
                           message: "Add the first thing that's due. Albus breaks it into steps and finds time for them before the deadline.",
                           actionTitle: "Add an assignment") {}
                EmptyLine(title: "Nothing's overdue", message: "Your 4 open assignments are all on time.",
                          isGoodNews: true, actionTitle: "Show all") {}
            }
            .padding(Tokens.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }
}
