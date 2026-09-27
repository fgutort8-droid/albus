import Foundation
import Testing
@testable import Albus

/// The CAPTCHA pass fetched while onboarding is on screen. Cloudflare accepts
/// each pass once and only for 300 s, and a nil answer must always mean "use
/// the visible check", never "skip the check".
@MainActor
@Suite("CAPTCHA pass fetched during onboarding")
struct CaptchaPrefetchTests {

    /// A clock the test moves by hand.
    private final class ManualClock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test("a ready pass is handed out once and never reused")
    func passIsSingleUse() async {
        let clock = ManualClock()
        let prefetch = CaptchaPrefetch(now: { clock.now })
        prefetch.received(token: "pass-1", generation: 0)

        #expect(await prefetch.take(waitingUpTo: .zero) == "pass-1")
        #expect(prefetch.state == .used)

        // Asking again fetches a new pass rather than handing back the spent one.
        #expect(await prefetch.take(waitingUpTo: .milliseconds(150)) == nil)
        #expect(prefetch.generation == 1)
    }

    @Test("a pass older than four minutes is never handed out")
    func stalePassIsRefused() async {
        let clock = ManualClock()
        let prefetch = CaptchaPrefetch(now: { clock.now })
        prefetch.received(token: "pass-1", generation: 0)

        clock.now += 241
        #expect(await prefetch.take(waitingUpTo: .milliseconds(150)) == nil)
        #expect(prefetch.generation == 1, "a stale pass is replaced, not used")
    }

    @Test("a pass still on its way is waited for")
    func inFlightPassIsAwaited() async {
        let prefetch = CaptchaPrefetch()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            prefetch.received(token: "pass-1", generation: 0)
        }

        #expect(await prefetch.take(waitingUpTo: .seconds(5)) == "pass-1")
    }

    @Test("a check that needs a person falls back to the visible one at once")
    func interactiveChallengeFallsBack() async {
        let prefetch = CaptchaPrefetch()
        prefetch.needsPerson(generation: 0)

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await prefetch.take(waitingUpTo: .seconds(5)) == nil)
        #expect(clock.now - started < .seconds(1))
    }

    @Test("a failed check falls back to the visible one at once")
    func failedCheckFallsBack() async {
        let prefetch = CaptchaPrefetch()
        prefetch.failed(generation: 0)

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await prefetch.take(waitingUpTo: .seconds(5)) == nil)
        #expect(clock.now - started < .seconds(1))
    }

    @Test("a check that never answers is abandoned rather than run beside the visible one")
    func stuckCheckIsAbandoned() async {
        let prefetch = CaptchaPrefetch()

        #expect(await prefetch.take(waitingUpTo: .milliseconds(150)) == nil)
        #expect(prefetch.state == .failed)

        // A pass that turns up afterwards is not kept for later.
        prefetch.received(token: "late", generation: 0)
        #expect(prefetch.state == .failed)
    }

    @Test("messages from an earlier page are ignored")
    func earlierPageIsIgnored() async {
        let prefetch = CaptchaPrefetch()
        prefetch.renew()

        prefetch.failed(generation: 0)
        prefetch.needsPerson(generation: 0)
        prefetch.received(token: "old", generation: 0)
        #expect(prefetch.state == .fetching)

        prefetch.received(token: "new", generation: 1)
        #expect(await prefetch.take(waitingUpTo: .zero) == "new")
    }

    @Test("an unused pass is swapped for a new one before it expires")
    func unusedPassIsRenewed() async throws {
        let prefetch = CaptchaPrefetch(freshFor: 0.05)
        prefetch.received(token: "pass-1", generation: 0)

        try await Task.sleep(for: .milliseconds(400))
        #expect(prefetch.generation == 1)
        #expect(prefetch.state == .fetching)
    }

    @Test("renewal stops when onboarding goes away")
    func stopCancelsRenewal() async throws {
        let prefetch = CaptchaPrefetch(freshFor: 0.05)
        prefetch.received(token: "pass-1", generation: 0)
        prefetch.stop()

        try await Task.sleep(for: .milliseconds(400))
        #expect(prefetch.generation == 0)
        #expect(prefetch.state == .ready)
    }

    @Test("a page that never answers is reloaded twice, then given up on")
    func stalledPageIsReloadedThenAbandoned() async throws {
        let prefetch = CaptchaPrefetch(stallAfter: 0.05)

        // Each load reports itself, as the real page does.
        prefetch.started(generation: prefetch.generation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(prefetch.generation == 1)
        #expect(prefetch.state == .fetching)

        prefetch.started(generation: prefetch.generation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(prefetch.generation == 2)

        prefetch.started(generation: prefetch.generation)
        try await Task.sleep(for: .milliseconds(300))
        #expect(prefetch.generation == 2)
        #expect(prefetch.state == .failed)
    }

    @Test("a page that answers is left alone by the watchdog")
    func answeredPageIsNotReloaded() async throws {
        let prefetch = CaptchaPrefetch(stallAfter: 0.05)
        prefetch.started(generation: 0)
        prefetch.received(token: "pass-1", generation: 0)

        try await Task.sleep(for: .milliseconds(300))
        #expect(prefetch.generation == 0)
        #expect(await prefetch.take(waitingUpTo: .zero) == "pass-1")
    }

    @Test("the hidden page tags every message with its challenge and stays invisible")
    func pageCarriesItsGeneration() {
        let html = CaptchaPrefetchPage.html(siteKey: "0xTEST", generation: 7)
        #expect(html.contains("generation: 7"))
        #expect(html.contains("data-appearance=\"interaction-only\""))
        #expect(html.contains("data-before-interactive-callback=\"onPerson\""))
    }
}
