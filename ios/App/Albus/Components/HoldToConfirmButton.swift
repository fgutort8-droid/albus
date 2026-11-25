import SwiftUI

/// A button that acts only once it has been held for `duration`.
///
/// For a choice that cannot be undone. A tap does nothing, so it cannot happen
/// by accident, and the student never types a word to prove they meant it. The
/// fill shows how long is left; letting go early runs it back to empty.
///
/// The fill eases out over the hold, slowing a little in its last stretch.
/// Enough that the end does not arrive with a jolt, not so much that it reads
/// as the app holding back: the curve keeps moving all the way and the whole
/// hold still takes `duration`, the same as the gesture's.
struct HoldToConfirmButton: View {
    let title: String
    var duration: Double = HoldToConfirmButton.standardDuration
    var isEnabled: Bool = true
    let action: () -> Void

    /// Long enough to be deliberate, short enough not to feel like a test.
    static let standardDuration = 2.0

    /// The fill's curve: even for most of the hold, easing only near the end.
    /// Its first control point sits on the diagonal, so the start is linear;
    /// the second pulls the last stretch in, so about the last 7% of the fill
    /// takes the last 18% of the time.
    static func fillAnimation(duration: Double) -> Animation {
        .timingCurve(0.4, 0.4, 0.7, 1.0, duration: duration)
    }

    @State private var progress: CGFloat = 0
    @State private var pressing = false
    @State private var completed = 0
    /// Whether the hold under the finger right now has reached the end. The
    /// fill's value is already 1 as soon as a press starts (the animation is
    /// what moves), so it cannot say whether a release came early.
    @State private var finishedThisHold = false

    private func label(_ color: Color) -> some View {
        Text(title)
            .font(Tokens.Typography.label)
            .fontWeight(.semibold)
            .foregroundStyle(color)
            .frame(maxWidth: .infinity)
    }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Tokens.Palette.danger.opacity(0.12))
            label(Tokens.Palette.danger)
            // The fill and its white label, cut to the fill's width, so the
            // words turn white exactly where the colour has reached them.
            ZStack {
                Capsule().fill(Tokens.Palette.danger)
                label(.white)
            }
            .mask(alignment: .leading) {
                GeometryReader { geometry in
                    Rectangle().frame(width: max(0, geometry.size.width * progress))
                }
            }
        }
        .frame(height: 50)
        .clipShape(Capsule())
        .contentShape(Capsule())
        .opacity(isEnabled ? 1 : 0.5)
        .onLongPressGesture(minimumDuration: duration, maximumDistance: 40) {
            guard isEnabled else { return }
            finishedThisHold = true
            completed += 1
            action()
            // Drained again after a moment, so a second hold (after a failure
            // the screen reports) shows its progress from empty.
            withAnimation(.easeOut(duration: 0.35).delay(0.6)) { progress = 0 }
        } onPressingChanged: { isPressing in
            guard isEnabled else { return }
            pressing = isPressing
            if isPressing {
                finishedThisHold = false
                withAnimation(Self.fillAnimation(duration: duration)) { progress = 1 }
            } else if !finishedThisHold {
                withAnimation(.easeOut(duration: 0.25)) { progress = 0 }
            }
        }
        .onChange(of: isEnabled) { _, enabled in
            if !enabled { progress = 0 }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: pressing) { _, now in now }
        .sensoryFeedback(.success, trigger: completed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityHint("Double-tap and hold for \(Int(duration)) seconds.")
        .accessibilityAddTraits(.isButton)
    }
}
