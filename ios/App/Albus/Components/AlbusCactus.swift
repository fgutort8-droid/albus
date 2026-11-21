import SwiftUI
import AlbusCore

/// Albus, the cactus.
///
/// Flat geometry, no image assets: the whole mascot is drawn from the same
/// primitives as `1 Prototype/mascot.jsx`, so it stays crisp at any size, works
/// in dark and light, and costs nothing to ship.
///
/// **Spike density encodes workload.** A calm week is a smooth cactus; a heavy
/// one bristles. That is the mascot doing real work — the student reads their
/// week before they read a number.
struct AlbusCactus: View {

    enum Mood: String, CaseIterable, Sendable {
        case calm, busy, cooked

        var spikeCount: Int {
            switch self {
            case .calm: 9
            case .busy: 15
            case .cooked: 24
            }
        }
        var spikeLength: CGFloat {
            switch self {
            case .calm: 6
            case .busy: 9
            case .cooked: 14
            }
        }
        var spikeHalfWidth: CGFloat {
            switch self {
            case .calm: 1.8
            case .busy: 2.0
            case .cooked: 2.4
            }
        }

        /// The scheduler's verdict, which is the only thing that decides a mood.
        ///
        /// This replaced a `forMinutes(_:)` that compared a day's scheduled
        /// minutes against absolute thresholds — calm under 120, cooked over
        /// 300. Those numbers could not be reached: study loads cap a day at
        /// 90, 180 or 270 minutes and the scheduler never exceeds capacity, so
        /// `cooked` was unreachable on every setting and most weeks pinned to
        /// `busy`. The cactus was effectively a still image.
        ///
        /// `Scheduler.workload` measures the same thing correctly, as a
        /// fraction of the capacity the student actually declared, and treats
        /// anything it could not place at all as cooked by definition.
        init(_ workload: WorkloadState) {
            switch workload {
            case .calm: self = .calm
            case .busy: self = .busy
            case .cooked: self = .cooked
            }
        }
    }

    var size: CGFloat = 40
    var mood: Mood = .busy
    /// Eyes closed, for a running focus session.
    var isResting: Bool = false
    /// How far the bud on his head has opened: 0 is the bud he always wears,
    /// 1 is in flower. Only the moment a purchase goes through opens it.
    var bloom: Double = 0

    /// The artwork is authored in a 120×152 box; everything below is in those
    /// units and scaled once at the end.
    private static let artSize = CGSize(width: 120, height: 152)
    private static let body = (cx: 60.0, cy: 70.0, rx: 33.0, ry: 42.0)

    private enum Palette {
        static let bodyMain = Color(red: 0.357, green: 0.784, blue: 0.522)   // #5BC885
        static let bodyHi = Color(red: 0.482, green: 0.847, blue: 0.624)     // #7BD89F
        static let bodyShadow = Color(red: 0.247, green: 0.659, blue: 0.392) // #3FA864
        static let spike = Color(red: 0.184, green: 0.561, blue: 0.322)      // #2F8F52
        static let potMain = Tokens.Palette.accent                           // #7C3AED
        static let potShadow = Tokens.Palette.accentPressed                  // #6D28D9
        static let eye = Color(red: 0.122, green: 0.239, blue: 0.169)        // #1F3D2B
        static let blush = Color(red: 0.914, green: 0.541, blue: 0.682)      // #E98AAE
        static let flower = Color(red: 0.957, green: 0.718, blue: 0.192)     // #F4B731
        static let flowerHi = Color(red: 1.0, green: 0.851, blue: 0.439)     // #FFD970
        static let petalShade = Color(red: 0.937, green: 0.678, blue: 0.208) // #EFAD35
    }

    var body: some View {
        Canvas { context, canvasSize in
            let scale = min(canvasSize.width / Self.artSize.width,
                            canvasSize.height / Self.artSize.height)
            context.scaleBy(x: scale, y: scale)
            draw(in: &context)
        }
        .frame(width: size, height: size * (Self.artSize.height / Self.artSize.width))
        .accessibilityHidden(true)
    }

    private func draw(in context: inout GraphicsContext) {
        drawArms(&context)
        drawSpikes(&context)
        drawBody(&context)
        drawFlower(&context)
        drawFace(&context)
        drawPot(&context)
    }

    // MARK: - Pieces

    private func drawArms(_ context: inout GraphicsContext) {
        // Left arm, raised.
        context.drawLayer { layer in
            // GraphicsContext rotates about the origin, so the pivot is moved
            // under it and back again.
            layer.translateBy(x: 28, y: 50)
            layer.rotate(by: .degrees(-18))
            layer.translateBy(x: -28, y: -50)
            layer.fill(Path(roundedRect: CGRect(x: 20, y: 34, width: 17, height: 40),
                            cornerRadius: 8.5), with: .color(Palette.bodyMain))
            layer.fill(Path(roundedRect: CGRect(x: 20, y: 34, width: 7, height: 40),
                            cornerRadius: 3.5), with: .color(Palette.bodyHi))
        }
        // Right arm, mid.
        context.drawLayer { layer in
            layer.translateBy(x: 92, y: 76)
            layer.rotate(by: .degrees(22))
            layer.translateBy(x: -92, y: -76)
            layer.fill(Path(roundedRect: CGRect(x: 84, y: 60, width: 16, height: 34),
                            cornerRadius: 8), with: .color(Palette.bodyMain))
            layer.fill(Path(roundedRect: CGRect(x: 93, y: 60, width: 7, height: 34),
                            cornerRadius: 3.5), with: .color(Palette.bodyShadow))
        }
    }

    private func drawSpikes(_ context: inout GraphicsContext) {
        var path = Path()
        appendSpikes(to: &path, cx: Self.body.cx, cy: Self.body.cy,
                     rx: Self.body.rx, ry: Self.body.ry,
                     count: mood.spikeCount, length: mood.spikeLength,
                     halfWidth: mood.spikeHalfWidth)
        // The raised arm gets its own smaller cluster.
        appendSpikes(to: &path, cx: 28, cy: 50, rx: 11, ry: 19,
                     count: 5 + mood.spikeCount / 5,
                     length: mood.spikeLength * 0.7,
                     halfWidth: mood.spikeHalfWidth * 0.8)
        context.fill(path, with: .color(Palette.spike))
    }

    /// Triangles around an ellipse, skipping the downward arc that the pot
    /// covers — spikes drawn there would poke through the front of the pot.
    private func appendSpikes(to path: inout Path, cx: Double, cy: Double,
                              rx: Double, ry: Double, count: Int,
                              length: CGFloat, halfWidth: CGFloat) {
        for i in 0..<count {
            let degrees = (360.0 / Double(count)) * Double(i) + 6
            if degrees > 52 && degrees < 128 { continue }

            let theta = degrees * .pi / 180
            let cosT = cos(theta), sinT = sin(theta)
            let baseX = cx + rx * cosT, baseY = cy + ry * sinT
            // Tangent, for the two base corners.
            let tx = -sinT, ty = cosT

            path.move(to: CGPoint(x: baseX + halfWidth * tx, y: baseY + halfWidth * ty))
            path.addLine(to: CGPoint(x: baseX + length * cosT, y: baseY + length * sinT))
            path.addLine(to: CGPoint(x: baseX - halfWidth * tx, y: baseY - halfWidth * ty))
            path.closeSubpath()
        }
    }

    private func drawBody(_ context: inout GraphicsContext) {
        let bodyRect = CGRect(x: Self.body.cx - Self.body.rx, y: Self.body.cy - Self.body.ry,
                              width: Self.body.rx * 2, height: Self.body.ry * 2)
        context.drawLayer { layer in
            layer.clip(to: Path(ellipseIn: bodyRect))
            layer.fill(Path(CGRect(origin: .zero, size: Self.artSize)),
                       with: .color(Palette.bodyMain))
            // Tonal banding rather than a gradient — flat by design.
            layer.fill(Path(ellipseIn: CGRect(x: 26, y: 26, width: 40, height: 60)),
                       with: .color(Palette.bodyHi))
            layer.fill(Path(ellipseIn: CGRect(x: 60, y: 58, width: 52, height: 68)),
                       with: .color(Palette.bodyShadow))
        }
    }

    private func drawFlower(_ context: inout GraphicsContext) {
        var stem = Path()
        stem.move(to: CGPoint(x: 60, y: 30))
        stem.addLine(to: CGPoint(x: 60, y: 18))
        context.stroke(stem, with: .color(Palette.bodyShadow),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        if bloom > 0 { drawPetals(context) }
        context.fill(Path(ellipseIn: CGRect(x: 54.5, y: 5.5, width: 11, height: 15)),
                     with: .color(Palette.flower))
        context.fill(Path(ellipseIn: CGRect(x: 56.2, y: 8.4, width: 3.6, height: 5.2)),
                     with: .color(Palette.flowerHi))
    }

    /// Five petals opening out of the bud, turning a little as they grow.
    /// Drawn before the bud so it stays the flower's middle; the two on the
    /// right take the body's shadow side.
    private func drawPetals(_ context: GraphicsContext) {
        let open = min(max(bloom, 0), 1)
        // The flower fades in as one shape: a layer takes the opacity of the
        // context it is drawn into, so where petals overlap is not darker.
        var faded = context
        faded.opacity = open
        faded.drawLayer { layer in
            // About the bud's centre, the way the arms pivot about theirs.
            layer.translateBy(x: 60, y: 13)
            layer.rotate(by: .degrees(-12 * (1 - open)))
            let grow = 0.18 + 0.82 * open
            layer.scaleBy(x: grow, y: grow)
            for (index, degrees) in [0.0, 72, 144, 216, 288].enumerated() {
                var petal = layer
                petal.rotate(by: .degrees(degrees))
                petal.fill(Path(ellipseIn: CGRect(x: -4.7, y: -13.8, width: 9.4, height: 14)),
                           with: .color(index == 1 || index == 2 ? Palette.petalShade : Palette.flowerHi))
            }
        }
    }

    private func drawFace(_ context: inout GraphicsContext) {
        // Blush.
        context.fill(Path(ellipseIn: CGRect(x: 39, y: 77, width: 10, height: 6)),
                     with: .color(Palette.blush.opacity(0.85)))
        context.fill(Path(ellipseIn: CGRect(x: 71, y: 77, width: 10, height: 6)),
                     with: .color(Palette.blush.opacity(0.85)))

        if isResting {
            // Closed eyes: two soft arcs. A focusing cactus is not staring.
            for cx in [50.0, 70.0] {
                var lid = Path()
                lid.move(to: CGPoint(x: cx - 5, y: 70))
                lid.addQuadCurve(to: CGPoint(x: cx + 5, y: 70),
                                 control: CGPoint(x: cx, y: 75))
                context.stroke(lid, with: .color(Palette.eye),
                               style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            }
        } else {
            for cx in [50.0, 70.0] {
                context.fill(Path(ellipseIn: CGRect(x: cx - 4.6, y: 65.4, width: 9.2, height: 9.2)),
                             with: .color(Palette.eye))
                context.fill(Path(ellipseIn: CGRect(x: cx - 6.2, y: 66.9, width: 3, height: 3)),
                             with: .color(.white))
            }
        }

        // Brows, lifted.
        var browL = Path()
        browL.move(to: CGPoint(x: 44, y: 60))
        browL.addQuadCurve(to: CGPoint(x: 55, y: 59), control: CGPoint(x: 50, y: 57))
        var browR = Path()
        browR.move(to: CGPoint(x: 65, y: 59))
        browR.addQuadCurve(to: CGPoint(x: 76, y: 60), control: CGPoint(x: 70, y: 57))
        for brow in [browL, browR] {
            context.stroke(brow, with: .color(Palette.eye),
                           style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }

        // Mouth.
        var mouth = Path()
        mouth.move(to: CGPoint(x: 54, y: 84))
        mouth.addQuadCurve(to: CGPoint(x: 66, y: 84), control: CGPoint(x: 60, y: 88))
        context.stroke(mouth, with: .color(Palette.eye),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawPot(_ context: inout GraphicsContext) {
        var pot = Path()
        pot.move(to: CGPoint(x: 30, y: 110))
        pot.addLine(to: CGPoint(x: 90, y: 110))
        pot.addLine(to: CGPoint(x: 84, y: 146))
        pot.addQuadCurve(to: CGPoint(x: 82, y: 148), control: CGPoint(x: 84, y: 148))
        pot.addLine(to: CGPoint(x: 38, y: 148))
        pot.addQuadCurve(to: CGPoint(x: 36, y: 146), control: CGPoint(x: 36, y: 148))
        pot.closeSubpath()

        context.fill(pot, with: .color(Palette.potMain))
        context.drawLayer { layer in
            layer.clip(to: pot)
            layer.fill(Path(CGRect(x: 68, y: 106, width: 30, height: 44)),
                       with: .color(Palette.potShadow))
        }
        context.fill(Path(roundedRect: CGRect(x: 26, y: 104, width: 68, height: 13),
                          cornerRadius: 5), with: .color(Palette.potShadow))
        context.fill(Path(roundedRect: CGRect(x: 26, y: 104, width: 68, height: 6),
                          cornerRadius: 3), with: .color(Palette.potMain))
    }
}

/// The cactus rising from behind something, showing only its top.
struct AlbusPeep: View {
    var visibleHeight: CGFloat = 56
    var mood: AlbusCactus.Mood = .busy

    var body: some View {
        // The face and upper body sit in roughly the top 60% of the artwork.
        let fullHeight = visibleHeight / 0.6
        let fullWidth = fullHeight * (120.0 / 152.0)
        AlbusCactus(size: fullWidth, mood: mood)
            .frame(width: fullWidth, height: visibleHeight, alignment: .top)
            .clipped()
    }
}

#Preview("Albus") {
    ZStack {
        BackgroundGradient()
        VStack(spacing: Tokens.Spacing.xl) {
            HStack(alignment: .bottom, spacing: Tokens.Spacing.l) {
                ForEach(AlbusCactus.Mood.allCases, id: \.self) { mood in
                    VStack {
                        AlbusCactus(size: 90, mood: mood)
                        Text(mood.rawValue)
                            .font(Tokens.Typography.caption)
                            .foregroundStyle(Tokens.Palette.inkSecondary)
                    }
                }
            }
            AlbusCactus(size: 120, mood: .calm, isResting: true)
            HStack(spacing: Tokens.Spacing.l) {
                AlbusCactus(size: 28)
                AlbusCactus(size: 40)
                AlbusPeep(visibleHeight: 44)
            }
        }
    }
}
