import SwiftUI

// Loading states. Where content is on its way, the screen shows its shape
// rather than a spinner: a spinner only says "wait", while a skeleton says
// what is coming and where, and the screen does not jump when it arrives.

/// One placeholder shape: a line of text, a number, a badge.
///
/// With no `width` it fills the width it is offered; with a `fraction` it takes
/// that share of it, which is how a paragraph of lines gets a ragged edge.
struct SkeletonBar: View {
    var width: CGFloat?
    var fraction: CGFloat = 1
    var height: CGFloat = 10
    var cornerRadius: CGFloat = 5

    var body: some View {
        if let width {
            shape.frame(width: width, height: height)
        } else {
            GeometryReader { proxy in
                shape.frame(width: proxy.size.width * min(max(fraction, 0), 1))
            }
            .frame(height: height)
        }
    }

    private var shape: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(Skeleton.fill)
    }
}

enum Skeleton {
    /// Warm grey, the hairline colour: visible on white cards and on the page
    /// background without competing with the content around it.
    static let fill = Tokens.Palette.hairline
    /// One sweep of the shine across a skeleton.
    static let sweep: TimeInterval = 1.4
}

extension View {
    /// Marks this view as a loading placeholder: a soft shine sweeps across its
    /// shapes, and VoiceOver reads the whole of it as one "Loading" element.
    ///
    /// The shine holds still with Reduce Motion on; the shapes alone still say
    /// "loading". Driven by the clock rather than an `onAppear` animation, so it
    /// keeps going when a lazy container recreates the view.
    func skeleton(label: String = "Loading") -> some View {
        modifier(SkeletonShine(label: label))
    }
}

private struct SkeletonShine: ViewModifier {
    let label: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay {
                if !reduceMotion {
                    TimelineView(.animation) { timeline in
                        GeometryReader { proxy in
                            let band = max(proxy.size.width * 0.45, 60)
                            let progress = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: Skeleton.sweep) / Skeleton.sweep
                            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.65), .white.opacity(0)],
                                           startPoint: .leading, endPoint: .trailing)
                                .frame(width: band)
                                .offset(x: -band + progress * (proxy.size.width + band))
                        }
                    }
                    // Only the shapes shine, never the space between them.
                    .mask { content }
                    .allowsHitTesting(false)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
    }
}
