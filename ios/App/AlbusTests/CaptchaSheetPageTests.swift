import JavaScriptCore
import Testing
@testable import Albus

/// The visible check's page, run in JavaScriptCore on a clock the test moves
/// by hand: when the page gives up on a check, and when it must not.
@MainActor
@Suite("The visible CAPTCHA check's page")
struct CaptchaSheetPageTests {

    /// The sheet's own script, with stand-ins for the browser's timers, the
    /// Turnstile script and the app's message handler.
    @MainActor
    private final class Page {
        private let context: JSContext = JSContext()

        init(scriptLoads: Bool = true) {
            run("""
                var now = 0, timers = [], nextId = 1, posted = [];
                function setTimeout(fn, ms){
                  var id = nextId++;
                  timers.push({ id: id, fn: fn, at: now + ms });
                  return id;
                }
                function clearTimeout(id){
                  timers = timers.filter(function(t){ return t.id !== id; });
                }
                function advanceTo(t){
                  for (;;) {
                    var due = timers.filter(function(x){ return x.at <= t; })
                      .sort(function(a, b){ return a.at - b.at || a.id - b.id; })[0];
                    if (!due) break;
                    clearTimeout(due.id);
                    now = due.at;
                    due.fn();
                  }
                  now = t;
                }
                var window = { webkit: { messageHandlers: { turnstile: {
                  postMessage: function(v){ posted.push(v); } } } } };
                """)
            if scriptLoads { run("window.turnstile = {};") }
            run(CaptchaSheet.pageScript)
        }

        /// Runs `js`, recording anything it throws as a test failure.
        @discardableResult
        func run(_ js: String) -> JSValue? {
            let value = context.evaluateScript(js)
            if let exception = context.exception {
                Issue.record("JavaScript threw: \(exception)")
                context.exception = nil
            }
            return value
        }

        /// Moves the page's clock to `seconds` after it loaded, firing timers.
        func advance(to seconds: Double) {
            run("advanceTo(\(Int((seconds * 1000).rounded())))")
        }

        /// What the page has sent the app so far.
        var posted: [String] { run("posted")?.toArray() as? [String] ?? [] }
    }

    @Test("a slow pass is kept: 30 s, slower than any measured")
    func slowPassIsKept() {
        let page = Page()
        page.advance(to: 30)
        page.run("onOK('pass-1')")
        page.advance(to: 600)

        #expect(page.posted == ["pass-1"])
    }

    @Test("a check that neither answers nor asks for the student gives up at the stall limit")
    func stalledCheckGivesUp() {
        let page = Page()
        page.advance(to: CaptchaSheet.stallAfter - 0.001)
        #expect(page.posted.isEmpty)

        page.advance(to: CaptchaSheet.stallAfter)
        #expect(page.posted == ["error"])
    }

    @Test("a challenge that asks for the student late is not cut off by the page")
    func lateChallengeIsNotCutOff() {
        let page = Page()
        page.advance(to: 45)
        page.run("onPerson()")
        page.advance(to: 600)
        #expect(page.posted.isEmpty, "Turnstile times the student itself")

        // Its timeout-callback, when the student runs out of time.
        page.run("onErr()")
        #expect(page.posted == ["error"])
    }

    @Test("a check that stalls after the student's part gives up in turn")
    func stallAfterChallengeGivesUp() {
        let page = Page()
        page.advance(to: 10)
        page.run("onPerson()")
        page.advance(to: 40)
        page.run("onPersonDone()")

        page.advance(to: 40 + CaptchaSheet.stallAfter - 0.001)
        #expect(page.posted.isEmpty)
        page.advance(to: 40 + CaptchaSheet.stallAfter)
        #expect(page.posted == ["error"])
    }

    @Test("a page whose Turnstile script never loads gives up at 20 s")
    func missingScriptGivesUpEarly() {
        let page = Page(scriptLoads: false)
        page.advance(to: 19.999)
        #expect(page.posted.isEmpty)

        page.advance(to: 20)
        #expect(page.posted == ["error"])
    }

    @Test("the page reports once: nothing follows a pass")
    func reportsOnce() {
        let page = Page()
        page.run("onOK('pass-1')")
        page.run("onErr()")
        page.advance(to: 600)

        #expect(page.posted == ["pass-1"])
    }

    @Test("every callback the widget is given exists on the page")
    func everyCallbackExists() {
        let html = CaptchaSheet.html(siteKey: "0xTEST")
        let names = html.matches(of: /data-(?:[a-z-]+-)?callback="(\w+)"/).map { String($0.1) }
        #expect(Set(names) == ["onOK", "onErr", "onPerson", "onPersonDone"])
        #expect(html.contains(CaptchaSheet.pageScript))

        let page = Page()
        for name in names {
            #expect(page.run("typeof \(name)")?.toString() == "function", "\(name)")
        }
    }
}
