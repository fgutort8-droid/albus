import SwiftUI

/// What a student sees the moment a purchase goes through.
///
/// `PaywallScreen` used to close on `.unlocked` without a word, so a student
/// who had just paid had no way to tell it had worked. This takes its place:
/// the plans screen's own night, Albus celebrating on the moon, and the four
/// things the plan they bought now gives them.
///
/// The motion is the purchase study in `Albus Motion notes.md`. Albus hops,
/// the bud on his head opens, his check lands — the one success haptic — and
/// the four lines are ticked off: 1.3 seconds in all. None of it stands
/// between the student and the app. "Start planning" works from the first
/// frame, a tap anywhere finishes the entrance, and with Reduce Motion the
/// screen opens finished.
struct PurchaseConfirmation: View {
    let plan: PaywallScreen.Plan
    /// One moment of the entrance, in seconds, held still. For snapshots.
    var frozenAt: Double?
    let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The entrance's first frame. Every pose is measured from it.
    @State private var start = Date.now
    /// The check has landed. Its change is the success haptic, so it is set
    /// once, whichever way the entrance ends.
    @State private var landed = false
    /// The entrance is over, or was cut short.
    @State private var settled = false
    /// Albus at rest, breathing. Started on its own, after the entrance.
    @State private var breathing = false
    @AccessibilityFocusState private var headingFocused: Bool

    private typealias Palette = PaywallScreen.Palette

    /// The lines the plans screen lists for this plan, without their detail.
    var benefits: [String] { plan.lines.map(\.0) }

    /// Nothing left to move: finished, skipped, held for a snapshot, or a
    /// student who asked the system for less motion.
    private var isStill: Bool { settled || reduceMotion || frozenAt != nil }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                TimelineView(.animation(paused: isStill)) { timeline in
                    page(at: moment(timeline.date), heroHeight: Self.heroHeight(for: geo.size))
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
        }
        .background(Palette.page.ignoresSafeArea())
        .sensoryFeedback(.success, trigger: landed)
        .task { await play() }
        .onChange(of: reduceMotion) { _, reduced in if reduced { finish() } }
        .onChange(of: settled) { _, isSettled in
            guard isSettled, !reduceMotion, frozenAt == nil else { return }
            // Its own transaction, a moment after the frame that put
            // everything in place, so the endless repeat is the only
            // animation it carries. Started in the same update as a skip, it
            // would also carry the jump from mid-hop and replay it forever.
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                    breathing = true
                }
            }
        }
    }

    /// Seconds into the entrance; past its end once nothing moves.
    private func moment(_ date: Date) -> Double {
        if let frozenAt { return frozenAt }
        return isStill ? .infinity : date.timeIntervalSince(start)
    }

    private func play() async {
        guard frozenAt == nil else { return }
        headingFocused = true
        guard !reduceMotion else { finish(); return }
        try? await Task.sleep(for: .seconds(max(0, Entrance.landing - Date.now.timeIntervalSince(start))))
        guard !Task.isCancelled else { return }
        landed = true
        try? await Task.sleep(for: .seconds(max(0, Entrance.end - Date.now.timeIntervalSince(start))))
        guard !Task.isCancelled else { return }
        settled = true
    }

    /// Everything in its final place at once — and the haptic, if the check
    /// had not landed yet: one per purchase, never two and never none.
    private func finish() {
        landed = true
        settled = true
    }

    // MARK: - Page

    private func page(at t: Double, heroHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            hero(at: t, height: heroHeight)
            heading.padding(.top, 24)
            Text("Here's what you have now.")
                .font(.system(size: 15))
                .foregroundStyle(Palette.gray)
                .padding(.top, 6)
            benefitList(at: t).padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .contentShape(Rectangle())
        .onTapGesture(perform: finish)
    }

    /// The plans screen's headline, with the plan where it has "You".
    private var heading: some View {
        (Text("You're on ") + Text(plan.title).foregroundColor(Palette.violet))
            .font(.system(size: 32, weight: .bold, design: .rounded))
            .kerning(-0.6)
            .foregroundStyle(Palette.ink)
            .accessibilityAddTraits(.isHeader)
            .accessibilityFocused($headingFocused)
    }

    private func benefitList(at t: Double) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(benefits.enumerated()), id: \.offset) { index, line in
                let tick = Entrance.check(index, at: t)
                HStack(spacing: 12) {
                    // The circles and the words are there from the first
                    // frame; only the ticks arrive, so nothing reflows.
                    Circle()
                        .fill(Tokens.Palette.accentWash)
                        .frame(width: 24, height: 24)
                        .overlay {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Palette.violet)
                                .scaleEffect(tick.scaleX)
                                .offset(y: tick.offsetY)
                                .opacity(tick.opacity)
                        }
                        .accessibilityHidden(true)
                    Text(line)
                        .font(.system(size: 15.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 46)
                .overlay(alignment: .bottom) {
                    if index < benefits.count - 1 {
                        Rectangle().fill(Palette.border).frame(height: 1)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 9) {
            Button {
                finish()
                onDone()
            } label: {
                Text("Start planning")
                    .font(.system(size: 16.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(Palette.violet, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: Palette.violet.opacity(0.45), radius: 14, x: 0, y: 10)
            }
            .buttonStyle(.plain)

            Text("Change or cancel any time in Settings.")
                .font(.system(size: 11.5))
                .foregroundStyle(Palette.gray)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(Palette.page)
    }

    // MARK: - Scene

    /// The moon from the plans screen, scaled into the panel the same way.
    private func hero(at t: Double, height: CGFloat) -> some View {
        Palette.night
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay {
                ZStack(alignment: .topLeading) {
                    MoonScene(animated: !reduceMotion && frozenAt == nil, runID: 0, showsCast: false)
                    cast(at: t)
                }
                .frame(width: MoonScene.width, height: MoonScene.height, alignment: .topLeading)
                .scaleEffect(height / MoonScene.height)
            }
            .clipShape(RoundedCornersShape(top: 120, bottom: 22))
            .accessibilityHidden(true)
    }

    /// Albus and his badge where the plans screen left them. The badge goes
    /// first, as it does there, so Albus — and now his flower — stand in
    /// front of it.
    private func cast(at t: Double) -> some View {
        let albus = Entrance.albus(at: t)
        let shadow = Entrance.shadow(at: t)
        let dust = Entrance.dust(at: t)
        let badge = Entrance.badge(at: t)
        let ring = Entrance.ring(at: t)
        let rest = breathing ? CGSize(width: 1.012, height: 1.025) : CGSize(width: 1, height: 1)

        return ZStack(alignment: .topLeading) {
            Color.clear

            ZStack {
                Circle()
                    .strokeBorder(Color(hex: 0xC4B5FD), lineWidth: 1.8)
                    .scaleEffect(ring.scaleX)
                    .opacity(ring.opacity)
                MoonScene.badge
                    .scaleEffect(x: badge.scaleX, y: badge.scaleY)
                    .offset(y: badge.offsetY)
                    .opacity(badge.opacity)
            }
            .frame(width: 48, height: 48)
            .offset(x: MoonScene.badgeOrigin.x, y: MoonScene.badgeOrigin.y)

            ZStack(alignment: .bottom) {
                MoonScene.groundShadow
                    .scaleEffect(x: shadow.scaleX, y: shadow.scaleY)
                    .opacity(shadow.opacity)
                Ellipse()
                    .strokeBorder(Color(hex: 0xE9D5FF), lineWidth: 1.4)
                    .frame(width: 84, height: 12)
                    .scaleEffect(x: dust.scaleX, y: dust.scaleY)
                    .opacity(dust.opacity)
                    .offset(y: 4)
                AlbusCactus(size: 104, mood: .calm, bloom: Entrance.bloom(at: t))
                    .scaleEffect(x: albus.scaleX, y: albus.scaleY, anchor: .bottom)
                    .scaleEffect(rest, anchor: .bottom)
                    .offset(y: albus.offsetY)
            }
            .frame(width: 104, height: 132, alignment: .bottom)
            .offset(x: MoonScene.cactusOrigin.x, y: MoonScene.cactusOrigin.y)
        }
    }

    /// The design's full 310pt scene where the phone is tall enough, shorter
    /// on a small phone so the four lines and the button still fit without
    /// scrolling. 410 is everything below the scene at the screen's text
    /// sizes, the button included.
    static func heroHeight(for size: CGSize) -> CGFloat {
        let full = MoonScene.height * max(size.width - 32, 0) / MoonScene.width
        return min(full, max(200, size.height - 410))
    }

    // MARK: - Entrance

    /// When each piece moves, in seconds from the first frame, and where it is
    /// at any moment. Poses depend on time alone, so a tap can put everything
    /// in its final place in one frame and a snapshot can hold any moment.
    enum Entrance {
        /// Albus leaves the ground and lands again.
        static let hopping = 0.12...0.60
        /// The bud opens.
        static let blooming = 0.42...0.78
        /// The badge drops in.
        static let dropping = 0.48...0.84
        /// The badge touches down: the success haptic.
        static let landing = 0.72
        /// The badge's ring spreads and fades.
        static let rippling = 0.72...1.08
        /// The dust where the pot comes down.
        static let settling = 0.48...0.76
        /// The last tick is in.
        static let end = 1.32

        /// Each line is ticked 0.12s after the one above it.
        static func ticking(_ line: Int) -> ClosedRange<Double> {
            let start = 0.78 + 0.12 * Double(line)
            return start...(start + 0.18)
        }

        struct Pose: Equatable {
            var offsetY: CGFloat = 0
            var scaleX: CGFloat = 1
            var scaleY: CGFloat = 1
            var opacity: Double = 1
        }

        private static let hopKeys = [0, 0.2, 0.5, 0.75, 1]

        /// A squash before he goes, a stretch in the air, a squash as he lands.
        static func albus(at t: Double) -> Pose {
            let p = progress(t, hopping)
            return Pose(offsetY: -keyframes(p, hopKeys, [0, 0, 14, 0, 0], .easeInOut),
                        scaleX: keyframes(p, hopKeys, [1, 1.035, 0.99, 1.035, 1], .easeInOut),
                        scaleY: keyframes(p, hopKeys, [1, 0.96, 1.015, 0.96, 1], .easeInOut))
        }

        /// The shadow stays on the ground, smaller and fainter while he is up.
        static func shadow(at t: Double) -> Pose {
            let p = progress(t, hopping)
            let scale = keyframes(p, hopKeys, [1, 1, 0.86, 1, 1], .easeInOut)
            return Pose(scaleX: scale, scaleY: scale,
                        opacity: keyframes(p, hopKeys, [1, 1, 0.7, 1, 1], .easeInOut))
        }

        static func bloom(at t: Double) -> Double {
            Curve.lift(progress(t, blooming))
        }

        static func badge(at t: Double) -> Pose {
            let p = progress(t, dropping)
            let keys = [0, 2.0 / 3, 1]
            return Pose(offsetY: keyframes(p, keys, [-12, 0, 0], .easeInOut),
                        scaleX: keyframes(p, keys, [0.84, 1.035, 1], .easeInOut),
                        scaleY: keyframes(p, keys, [0.84, 0.96, 1], .easeInOut),
                        opacity: keyframes(p, keys, [0, 1, 1], .easeInOut))
        }

        /// Not there until the badge lands, then one ring outwards.
        static func ring(at t: Double) -> Pose {
            let p = Curve.quick(progress(t, rippling))
            let scale = 0.88 + 0.67 * p
            return Pose(scaleX: scale, scaleY: scale,
                        opacity: t < rippling.lowerBound ? 0 : 0.55 * (1 - p))
        }

        static func dust(at t: Double) -> Pose {
            let p = Curve.quick(progress(t, settling))
            let scale = 0.48 + 0.92 * p
            return Pose(scaleX: scale, scaleY: scale,
                        opacity: t < settling.lowerBound ? 0 : 0.48 * (1 - p))
        }

        static func check(_ line: Int, at t: Double) -> Pose {
            let p = Curve.quick(progress(t, ticking(line)))
            let scale = 0.84 + 0.16 * p
            return Pose(offsetY: 2 * (1 - p), scaleX: scale, scaleY: scale, opacity: p)
        }

        /// How far through `span` the moment `t` is: 0 before it, 1 after it.
        static func progress(_ t: Double, _ span: ClosedRange<Double>) -> Double {
            min(max((t - span.lowerBound) / (span.upperBound - span.lowerBound), 0), 1)
        }

        /// A value through keyframes at fractions `keys` of the way, eased
        /// between each pair as CSS eases a keyframe animation.
        static func keyframes(_ p: Double, _ keys: [Double], _ values: [Double], _ curve: Curve) -> Double {
            guard p > keys[0] else { return values[0] }
            // Strictly before each key, so a moment on a key, or past the
            // last, returns that key's value exactly rather than nearly.
            for index in 1..<keys.count where p < keys[index] {
                let local = (p - keys[index - 1]) / (keys[index] - keys[index - 1])
                return values[index - 1] + (values[index] - values[index - 1]) * curve(local)
            }
            return values[values.count - 1]
        }
    }

    /// A CSS `cubic-bezier`, so the timings read as the motion study wrote them.
    struct Curve {
        let x1: Double, y1: Double, x2: Double, y2: Double

        static let easeInOut = Curve(x1: 0.42, y1: 0, x2: 0.58, y2: 1)
        /// `Tokens.Motion.quick`'s ease-out.
        static let quick = Curve(x1: 0, y1: 0, x2: 0.58, y2: 1)
        /// The curve the plans screen's own entrance uses.
        static let lift = Curve(x1: 0.22, y1: 1, x2: 0.36, y2: 1)

        /// The curve's height where it is `x` of the way along. Its x only ever
        /// rises, so halving the interval finds the point to well under a
        /// thousandth in twenty steps.
        func callAsFunction(_ x: Double) -> Double {
            guard x > 0 else { return 0 }
            guard x < 1 else { return 1 }
            var low = 0.0, high = 1.0
            for _ in 0..<20 {
                let mid = (low + high) / 2
                if Self.bezier(mid, x1, x2) < x { low = mid } else { high = mid }
            }
            return Self.bezier((low + high) / 2, y1, y2)
        }

        /// One coordinate of a cubic Bézier from 0 to 1 through `a` and `b`.
        private static func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double {
            let u = 1 - t
            return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
        }
    }
}

#Preview("Plus, landing") {
    PurchaseConfirmation(plan: .plus, frozenAt: 0.74) {}
}

#Preview("Pro") {
    PurchaseConfirmation(plan: .pro) {}
}
