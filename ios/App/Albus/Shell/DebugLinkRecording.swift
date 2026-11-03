import SwiftUI

/// Lets UI tests check where a link goes without the network.
///
/// With `-albus.debug.recordLinks`, links and `openURL` calls are recorded
/// instead of opened, and the last one is shown, tiny, under the identifier
/// `debug.lastOpenedURL`. CI can then assert the exact address a Terms or
/// Privacy link opens; `LegalLinksUITests`, which opens the live pages, needs
/// the network and runs only on a developer's machine. Compiled out of
/// Release.
struct DebugLinkRecording: ViewModifier {
    func body(content: Content) -> some View {
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-albus.debug.recordLinks") {
            RecordingLinks(content: content)
        } else {
            content
        }
#else
        content
#endif
    }
}

#if DEBUG
private struct RecordingLinks<Content: View>: View {
    let content: Content
    @State private var last: URL?

    var body: some View {
        content
            .environment(\.openURL, OpenURLAction { url in
                last = url
                return .handled
            })
            .overlay(alignment: .bottomLeading) {
                Text(last?.absoluteString ?? "none")
                    .font(.system(size: 6))
                    .opacity(0.02)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("debug.lastOpenedURL")
            }
    }
}
#endif
