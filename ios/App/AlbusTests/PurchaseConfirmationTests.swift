import CoreGraphics
import Testing
@testable import Albus

/// The moment a purchase goes through, as numbers: when each piece moves and
/// where it comes to rest. What it looks like is in `PaywallSnapshots`.
@MainActor
@Suite("Purchase confirmation")
struct PurchaseConfirmationTests {
    private typealias Entrance = PurchaseConfirmation.Entrance
    private typealias Curve = PurchaseConfirmation.Curve

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.0001 }

    private func atRest(_ pose: Entrance.Pose) -> Bool {
        close(pose.offsetY, 0) && close(pose.scaleX, 1) && close(pose.scaleY, 1) && close(pose.opacity, 1)
    }

    @Test("it lists the four lines the plans screen sold")
    func benefitsAreThePlansScreensLines() {
        #expect(PurchaseConfirmation(plan: .plus) {}.benefits
                == ["Unlimited AI plans within fair use", "10 active tasks",
                    "5 synced rubrics", "2 markings a week"])
        #expect(PurchaseConfirmation(plan: .pro) {}.benefits
                == ["Unlimited AI plans within fair use", "Unlimited tasks",
                    "Unlimited synced rubrics", "5 markings a week"])
    }

    @Test("on the first frame Albus stands still and nothing has arrived yet")
    func firstFrame() {
        #expect(atRest(Entrance.albus(at: 0)))
        #expect(Entrance.badge(at: 0).opacity == 0)
        #expect(Entrance.ring(at: 0).opacity == 0)
        #expect(Entrance.dust(at: 0).opacity == 0)
        #expect(Entrance.bloom(at: 0) == 0)
        for line in 0..<4 { #expect(Entrance.check(line, at: 0).opacity == 0) }
    }

    @Test("Albus is 14pt up halfway through the hop and back down at its end")
    func hop() {
        let span = Entrance.hopping
        let apex = span.lowerBound + (span.upperBound - span.lowerBound) / 2
        #expect(close(Entrance.albus(at: apex).offsetY, -14))
        #expect(atRest(Entrance.albus(at: span.upperBound)))
        // The dust rises where he lands, not before.
        #expect(close(Entrance.settling.lowerBound,
                      span.lowerBound + 0.75 * (span.upperBound - span.lowerBound)))
    }

    @Test("the check is down at the haptic, and everything is in well inside 2.5 seconds")
    func landing() {
        let badge = Entrance.badge(at: Entrance.landing)
        #expect(close(badge.offsetY, 0))
        #expect(close(badge.opacity, 1))
        #expect(Entrance.ring(at: Entrance.landing).opacity > 0)
        #expect(Entrance.landing < Entrance.end)
        #expect(Entrance.ticking(3).upperBound <= Entrance.end + 0.0001)
        #expect(Entrance.end <= 2.5)
    }

    @Test("a finished or skipped entrance has every piece at rest")
    func finalFrame() {
        let end = Double.infinity
        #expect(atRest(Entrance.albus(at: end)))
        #expect(atRest(Entrance.badge(at: end)))
        #expect(Entrance.ring(at: end).opacity == 0)
        #expect(Entrance.dust(at: end).opacity == 0)
        #expect(Entrance.bloom(at: end) == 1)
        for line in 0..<4 { #expect(atRest(Entrance.check(line, at: end))) }
    }

    @Test("each curve runs from 0 to 1 and never backwards")
    func curves() {
        for curve in [Curve.easeInOut, Curve.quick, Curve.lift] {
            #expect(curve(0) == 0)
            #expect(curve(1) == 1)
            var last = 0.0
            for step in 1...100 {
                let value = curve(Double(step) / 100)
                #expect(value >= last - 1e-9)
                last = value
            }
        }
        // Symmetric, so it passes the middle at the middle.
        #expect(close(Curve.easeInOut(0.5), 0.5))
    }

    @Test("the scene is full size on a large phone and shrinks to fit a small one")
    func heroHeight() {
        #expect(PurchaseConfirmation.heroHeight(for: CGSize(width: 402, height: 778)) == 310)
        let small = PurchaseConfirmation.heroHeight(for: CGSize(width: 375, height: 647))
        #expect(small >= 200 && small < 250)
    }
}
