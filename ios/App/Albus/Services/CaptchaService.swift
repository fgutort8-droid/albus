import SwiftUI
import WebKit

/// Presents a Cloudflare Turnstile challenge and returns the token Supabase
/// needs to accept an anonymous sign-up.
///
/// **Why this exists.** Anonymous sign-up is the whole onboarding — there is no
/// signup wall — which also makes it the one endpoint a script can call in bulk
/// to farm accounts and burn AI budget. A CAPTCHA is what makes that expensive.
///
/// **Why it is off unless configured.** The moment Supabase has CAPTCHA
/// enabled it rejects *every* sign-up that arrives without a token. Enabling it
/// before the client can produce one breaks every new install, so the switch is
/// the presence of a site key: no key, no challenge, sign-up proceeds exactly
/// as before. See `ios/README.md` for the three steps that turn it on.
///
/// **Why Turnstile and not an SDK.** It runs in a plain `WKWebView`, so this
/// costs zero third-party dependencies in an app that deliberately has almost
/// none. hCaptcha would mean shipping their SDK to do the same job.
@MainActor
enum Captcha {

    /// Empty when the build has no site key — the normal state today.
    static var siteKey: String {
        let key = Bundle.main.infoDictionary?["TURNSTILE_SITE_KEY"] as? String ?? ""
        // The template ships a placeholder; treat it as absent.
        return key.contains("YOUR_") ? "" : key
    }

    static var isEnabled: Bool { !siteKey.isEmpty }

    /// The origin the widget is served from.
    ///
    /// Turnstile validates the page's hostname against the domains configured
    /// for the site key, and a `WKWebView` loading a raw string reports
    /// `about:blank`, which never matches. Loading the same HTML with an
    /// explicit base URL gives it a real origin to check.
    static var origin: String {
        Bundle.main.infoDictionary?["TURNSTILE_ORIGIN"] as? String ?? "https://albus.app"
    }
}

/// The challenge itself, as a sheet.
///
/// Turnstile is usually invisible — most callers are silently approved and this
/// closes on its own — so it deliberately shows nothing but a spinner until the
/// widget decides it needs a human.
struct CaptchaSheet: UIViewRepresentable {
    /// Called with a token on success, or `nil` if the challenge could not be
    /// completed. A nil result is a refusal to proceed, never a silent pass:
    /// the caller must not sign up without a token once CAPTCHA is enabled.
    let completion: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Nothing this page does should persist between launches.
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: "turnstile")

        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.navigationDelegate = context.coordinator
        view.loadHTMLString(Self.html(siteKey: Captcha.siteKey),
                            baseURL: URL(string: Captcha.origin))
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController
            .removeScriptMessageHandler(forName: "turnstile")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        private let completion: (String?) -> Void
        /// Guards against the widget reporting twice — a second callback after
        /// the caller has already signed up would sign them up again.
        private var hasFinished = false

        init(completion: @escaping (String?) -> Void) {
            self.completion = completion
        }

        func userContentController(_ controller: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard !hasFinished else { return }
            hasFinished = true

            // The page only ever posts a token string or an error marker.
            // Anything else is treated as a failure rather than trusted.
            if let token = message.body as? String, !token.isEmpty, token != "error" {
                completion(token)
            } else {
                completion(nil)
            }
        }

        nonisolated func webView(_ webView: WKWebView,
                                 didFail navigation: WKNavigation!,
                                 withError error: Error) {
            Task { @MainActor in
                guard !hasFinished else { return }
                hasFinished = true
                completion(nil)
            }
        }
    }

    /// How long the check may work on its own, without answering or asking
    /// for the student, before the sheet gives up on it. Slow is not stalled:
    /// on a fresh simulator a pass through this sheet took 29 s (27 Sep
    /// 2026), and a 20 s limit, this sheet's first, would have sent that
    /// student back to Retry 9 s before it arrived. The quiet check's
    /// watchdog waits as long, for the same reason.
    ///
    /// A student solving a challenge is not on this clock. Turnstile times
    /// them itself and reports it through `timeout-callback`.
    static let stallAfter: TimeInterval = 60

    /// The widget page. The site key is the only value interpolated from
    /// outside this file, and it comes from the app's own bundle, never from
    /// user input or the network.
    static func html(siteKey: String) -> String {
        """
        <!doctype html>
        <html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async defer></script>
        <style>
          html,body { margin:0; height:100%; background:transparent;
                      display:flex; align-items:center; justify-content:center;
                      font: 15px -apple-system, system-ui; color:#6E6757; }
        </style>
        </head><body>
        <div id="widget"
             class="cf-turnstile"
             data-sitekey="\(siteKey)"
             data-callback="onOK"
             data-error-callback="onErr"
             data-timeout-callback="onErr"
             data-before-interactive-callback="onPerson"
             data-after-interactive-callback="onPersonDone"
             data-appearance="interaction-only"></div>
        <script>
        \(pageScript)
        </script>
        </body></html>
        """
    }

    /// What the page does with the widget's answers. It reports exactly once:
    /// a pass, or "error". Kept apart from the markup so tests can run it.
    static var pageScript: String {
        """
        var done = false, stall = null;
        function post(v){
          if (done) return;
          done = true;
          clearTimeout(stall);
          window.webkit.messageHandlers.turnstile.postMessage(v);
        }
        function onOK(t){ post(t); }
        function onErr(){ post("error"); }
        // The stall clock runs only while the check works on its own. It
        // stops while the student solves a challenge and starts afresh once
        // they are done, so neither a slow check nor a slow student is cut off.
        function watch(){ clearTimeout(stall); stall = setTimeout(onErr, \(Int(stallAfter * 1000))); }
        function onPerson(){ clearTimeout(stall); stall = null; }
        function onPersonDone(){ watch(); }
        watch();
        // If the Turnstile script itself never loads, nothing will answer.
        setTimeout(function(){ if (!window.turnstile) { onErr(); } }, 20000);
        """
    }
}
