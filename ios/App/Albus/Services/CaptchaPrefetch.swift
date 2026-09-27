import SwiftUI
import WebKit

/// Runs the Turnstile check while the student answers the onboarding
/// questions, so the pass is usually ready by the time they tap "Build my plan".
///
/// **Why.** On the simulator (27 Sep 2026) Turnstile took 3–14 s to issue a
/// pass, and 28 s on a cold simulator under heavy load. Started at the tap,
/// all of that was spinner before the account existed. Started when
/// onboarding opens, it has the whole of onboarding to finish.
///
/// **Two rules the pass imposes.** Supabase checks it with Cloudflare, which
/// accepts each pass once and only for 300 s after it was issued. So a pass is
/// handed out at most once, only while comfortably fresh, and a new one is
/// fetched before the old one ages out.
///
/// **What it never does.** It never shows anything, and it never decides that a
/// check can be skipped. When Cloudflare wants a person to interact, or the
/// quiet check fails, `take(waitingUpTo:)` returns nil and onboarding falls back
/// to the visible `CaptchaSheet`: the flow that existed before this.
@Observable
@MainActor
final class CaptchaPrefetch {
    enum State: Equatable {
        /// The hidden page is loading a challenge.
        case fetching
        /// A pass is waiting to be used.
        case ready
        /// The last pass went to a sign-up. The next one is fetched only when
        /// asked for, so a successful sign-up does not start a challenge nobody
        /// needs.
        case used
        /// Cloudflare wants a person to interact, which a hidden page cannot do.
        case needsPerson
        case failed
    }

    private(set) var state: State = .fetching
    /// Which challenge the hidden page should be running. Bumped to load a fresh
    /// one; messages from an earlier page are ignored.
    private(set) var generation = 0

    // Bookkeeping no view reads, so changing it redraws nothing. The page
    // updates the watchdog while SwiftUI is building it.
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var receivedAt: Date?
    @ObservationIgnored private var renewal: Task<Void, Never>?
    @ObservationIgnored private var watchdog: Task<Void, Never>?
    /// Reloads in a row since a page last answered. See `started(generation:)`.
    @ObservationIgnored private var reloads = 0
    /// How long a pass is handed out for. Cloudflare's limit is 300 s; the rest
    /// is time for the sign-up to reach Supabase and Supabase to reach Cloudflare.
    private let freshFor: TimeInterval
    /// A page with no answer by then is reloaded. Generous on purpose: a pass
    /// took up to 28 s on a cold, loaded simulator, and a watchdog that
    /// reloads a slow page just starts it over. It was 25 s once, and on a cold
    /// simulator it did exactly that, three times running.
    private let stallAfter: TimeInterval
    /// Stalled pages reloaded before the quiet check gives up for this session.
    private static let maxReloads = 2
    private let now: () -> Date

    init(freshFor: TimeInterval = 240, stallAfter: TimeInterval = 60,
         now: @escaping () -> Date = Date.init) {
        self.freshFor = freshFor
        self.stallAfter = stallAfter
        self.now = now
    }

    // MARK: Asking for the pass

    /// The pass, if one is ready, or once one arrives within `timeout`.
    ///
    /// Handing it out uses it up. A pass that is stale or already used is never
    /// returned: a new one is fetched instead, and waited for like any other.
    /// Nil means "use the visible check", never "skip the check".
    func take(waitingUpTo timeout: Duration) async -> String? {
        switch state {
        case .ready where isFresh:
            return consume()
        case .ready, .used:
            renew()
        case .fetching:
            break
        case .needsPerson, .failed:
            return nil
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while state == .fetching, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        if state == .ready, isFresh { return consume() }
        // The caller has waited long enough: treat the page as stuck, so it
        // stops while the visible check runs instead of running beside it.
        if state == .fetching { settle(.failed) }
        return nil
    }

    /// Loads a fresh challenge in the hidden page.
    func renew() {
        reloads = 0
        reload()
    }

    /// Stops the automatic renewal and the stall watchdog. Called when
    /// onboarding goes away.
    func stop() {
        renewal?.cancel()
        renewal = nil
        watchdog?.cancel()
        watchdog = nil
    }

    // MARK: Messages from the hidden page

    /// The page began loading `generation`. If it has not answered within
    /// `stallAfter`, it is reloaded, at most `maxReloads` times in a row: a
    /// page can stall (the app sent to the background mid-check, say) and a
    /// stalled one would otherwise leave onboarding without a pass for good.
    func started(generation: Int) {
        guard generation == self.generation, state == .fetching else { return }
        watchdog?.cancel()
        let stallAfter = stallAfter
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(stallAfter))
            guard !Task.isCancelled, let self, self.state == .fetching,
                  self.generation == generation else { return }
            if self.reloads < Self.maxReloads {
                self.reloads += 1
                self.reload()
            } else {
                self.settle(.failed)
            }
        }
    }

    func received(token: String, generation: Int) {
        guard generation == self.generation, state == .fetching, !token.isEmpty else { return }
        self.token = token
        receivedAt = now()
        settle(.ready)

        // Swap it for a new one before it goes stale, so a student who takes
        // their time still never waits.
        renewal?.cancel()
        let freshFor = freshFor
        renewal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(freshFor))
            guard !Task.isCancelled, let self, self.state == .ready,
                  self.token == token else { return }
            self.renew()
        }
    }

    func needsPerson(generation: Int) {
        guard generation == self.generation, state == .fetching else { return }
        settle(.needsPerson)
    }

    func failed(generation: Int) {
        guard generation == self.generation, state == .fetching else { return }
        settle(.failed)
    }

    // MARK: Private

    /// Starts the next challenge, keeping count of stalled reloads.
    private func reload() {
        renewal?.cancel()
        renewal = nil
        watchdog?.cancel()
        watchdog = nil
        token = nil
        receivedAt = nil
        generation += 1
        state = .fetching
    }

    /// Ends the current challenge, with whatever it came to.
    private func settle(_ outcome: State) {
        watchdog?.cancel()
        watchdog = nil
        reloads = 0
        state = outcome
    }

    private var isFresh: Bool {
        guard let receivedAt else { return false }
        return now().timeIntervalSince(receivedAt) < freshFor
    }

    private func consume() -> String? {
        let pass = token
        renewal?.cancel()
        renewal = nil
        token = nil
        receivedAt = nil
        state = .used
        return pass
    }
}

/// The hidden page that runs `CaptchaPrefetch`'s challenge.
///
/// Onboarding places it behind its own opaque background, widget-sized and all
/// but transparent, with no taps and no accessibility. It is on screen rather
/// than hidden or off screen because WebKit may throttle a page, or a
/// cross-origin frame, it thinks nobody can see.
struct CaptchaPrefetchPage: UIViewRepresentable {
    let prefetch: CaptchaPrefetch
    /// Passed as a value so that SwiftUI calls `updateUIView` when it changes.
    let generation: Int

    func makeCoordinator() -> Coordinator { Coordinator(prefetch: prefetch) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing this page does should persist between launches.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "turnstile")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        // No navigation delegate. The page is a local string, and a failure
        // reported for "the current navigation" could belong to a page that
        // has since been replaced. A script that never loads or a widget that
        // never answers is caught by the page's own guard and by the
        // `CaptchaPrefetch` watchdog, and both know which challenge they
        // belong to.
        context.coordinator.load(generation, into: view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        if context.coordinator.loaded != generation {
            context.coordinator.load(generation, into: view)
        }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: "turnstile")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler {
        private weak var prefetch: CaptchaPrefetch?
        private(set) var loaded = -1

        init(prefetch: CaptchaPrefetch) {
            self.prefetch = prefetch
        }

        func load(_ generation: Int, into view: WKWebView) {
            loaded = generation
            view.loadHTMLString(CaptchaPrefetchPage.html(siteKey: Captcha.siteKey,
                                                         generation: generation),
                                baseURL: URL(string: Captcha.origin))
            prefetch?.started(generation: generation)
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            // The page only ever posts these three shapes. Anything else is a
            // failure rather than something to trust.
            guard let prefetch,
                  let body = message.body as? [String: Any],
                  let generation = body["generation"] as? Int,
                  let kind = body["kind"] as? String else { return }
            switch kind {
            case "token":
                if let token = body["value"] as? String {
                    prefetch.received(token: token, generation: generation)
                } else {
                    prefetch.failed(generation: generation)
                }
            case "interactive":
                prefetch.needsPerson(generation: generation)
            default:
                prefetch.failed(generation: generation)
            }
        }
    }

    /// The widget page. The site key and the generation are the only values
    /// interpolated: one from the app's own bundle, the other an Int.
    static func html(siteKey: String, generation: Int) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
        </head><body>
        <div class="cf-turnstile"
             data-sitekey="\(siteKey)"
             data-callback="onOK"
             data-error-callback="onErr"
             data-timeout-callback="onErr"
             data-expired-callback="onErr"
             data-before-interactive-callback="onPerson"
             data-refresh-expired="never"
             data-appearance="interaction-only"></div>
        <script>
          var done = false;
          function post(kind, value){
            if (done) return; done = true;
            window.webkit.messageHandlers.turnstile.postMessage(
              { kind: kind, value: value, generation: \(generation) });
          }
          function onOK(t){ post("token", t); }
          function onErr(){ post("error"); }
          function onPerson(){ post("interactive"); }
          // If the script itself never loads, give up rather than wait forever.
          setTimeout(function(){ if (!window.turnstile) { onErr(); } }, 20000);
        </script>
        </body></html>
        """
    }
}
