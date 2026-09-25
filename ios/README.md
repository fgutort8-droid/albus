# Albus — iOS

```
AlbusCore/     Swift package: models, scheduler, estimator, design tokens
App/Albus/     The app target (SwiftUI)
project.yml    Xcode project definition — the source of truth
```

## Building

The `.xcodeproj` is **generated, not committed** — that file is machine-written,
merges badly, and hides real changes in noise.

```bash
brew install xcodegen        # once
cd ios && xcodegen generate  # after editing project.yml
open Albus.xcodeproj
```

The core logic builds and tests without Xcode at all, which is where most of
the work happens:

```bash
cd ios/AlbusCore && swift test
```

## ⚠️ Session persistence needs a Team ID

`App/Albus/Albus.entitlements` declares the Keychain access group the auth
session needs. It only takes effect on a **signed** build.

Credentials are stored only in Keychain in all configurations. Existing legacy
copies migrate into Keychain when it is available and are then removed from
UserDefaults. A failed migration keeps the existing copy solely for retry; it
cannot authenticate the student until it has been secured. If secure storage is unavailable, sign-in reports an error and
can be retried after unlocking the device or correcting the build's signing.
Unit tests inject isolated storage and never need a production account.

Keychain uses `kSecAttrAccessibleAfterFirstUnlock`, preserving background token
refresh and the existing service identifier. Items on a signed device survive
app deletion; server-side spending controls remain authoritative.

Enabling ad-hoc signing to get the entitlement on the simulator was tried and
reverted: it produced an `application-identifier` the simulator container did
not match, and SwiftData then failed with *Sandbox access to file-write-create
denied*. A working app is worth more than an entitlement that cannot be
verified here.

Quota enforcement does not depend on any of this. The free accounts' spend
fuse (`private.ai_pool_budget`) bounds abuse regardless of how many accounts
exist, and
`account_risk` (0035) notices a device that has signed up five times this
afternoon — neither of which cares whether the Keychain held.

## ⚠️ Signing is deliberately unset

The app builds and runs in the simulator as is. To run on a **physical device**
or ship to TestFlight, set the Apple Team ID:

1. Find it under Membership in the Apple Developer account (10 characters).
2. In `project.yml`, under `settings.base`, add:
   ```yaml
   DEVELOPMENT_TEAM: XXXXXXXXXX
   CODE_SIGNING_ALLOWED: YES
   ```
3. `xcodegen generate`

Nothing else depends on this. It was left out so the project could be set up
without waiting on the account.

## What's built

| | |
|---|---|
| **Scheduler** | Places work in time and re-places it when reality diverges. 25 tests. |
| **Estimator** | Learns how long *this* student actually takes. 10 tests. |
| **Tokens** | Colours, type, spacing sampled from the design exports. |
| **App shell** | Full-screen gradient + floating tab bar, four tabs. |
| **Notifications** | Twelve kinds, planned purely in `AlbusCore`. 58 tests. |
| **Grader** | Marks work against the student's own rubric and gives a real grade. |
| **Plans** | Free, Plus and Pro. Every limit is a row in `public.plans`, enforced in Postgres. |
| **Settings** | The fourth tab: plan and meters, profile, notifications, version. |

Every tab is a real screen: Home is the assignment list, Rubrics owns saved
rubrics, Tools is the catalogue, Settings owns the plan and the preferences.
Focus Mode, the plan editor, grading, the month calendar and notification
settings all exist.

**Ask Albus is not a tab.** It was, and the tell that it should not have been is
that the tab carried an assignment *picker* — a surface with no context of its
own, asking the student to supply it. It now opens from inside an assignment,
where the rubric and the deadline are already known, and it is Pro-only. See
`AskAlbus.swift`.

## Two things that are load-bearing

**The gradient lives inside `Screen`, not behind the `NavigationStack`.** A
navigation stack paints its own opaque surface, so a gradient placed behind one
is simply covered — the first version of this shipped a plain white background
for exactly that reason. `Screen` also applies the bottom inset the floating
tab bar needs, so no screen has to remember either concern.

**Views never name a colour.** Everything comes from `Tokens`. Subject colour
is a property of the course, not the card that shows it: HIST is red on every
screen, and a view maps the enum rather than picking.


---

## CAPTCHA — built, and off until you add a key

Onboarding exists now, and with it the CAPTCHA plumbing. **The client side is
done**: `Services/CaptchaService.swift` presents a Cloudflare Turnstile
challenge in a `WKWebView` and passes the token to `signInAnonymously`.

**It is deliberately inert until configured.** The switch is the presence of a
site key: with `TURNSTILE_SITE_KEY` empty, no challenge is shown and sign-up
behaves exactly as before. This matters because the two sides must be turned on
*together* — a secret configured in Supabase without a key in the app rejects
every new sign-up, and a key in the app without the secret verifies nothing.

**Why Turnstile rather than hCaptcha** (`config.toml` still names hcaptcha, and
should be updated when you switch it on): Turnstile runs in a plain WebView, so
it costs zero third-party SDKs in an app that has almost none, and it is free at
higher volume.

### Turning it on — all three, in one go

1. **Cloudflare** → Turnstile → create a widget. Set its hostname to the value
   of `TURNSTILE_ORIGIN` in your `Config.xcconfig` (default `albus.app`). The
   hostname must match: Turnstile checks the page origin, which is why the
   WebView loads its HTML with an explicit base URL rather than `about:blank`.
2. **App** → paste the **site** key into `TURNSTILE_SITE_KEY` in
   `App/Config.xcconfig`, and rebuild.
3. **Supabase** → Authentication → Settings → Bot and Abuse Protection → enable,
   provider Turnstile, paste the **secret** key.

### Then verify, on a fresh install

Delete the app first — an existing install has a session and will never hit
sign-up, so testing on it proves nothing. A fresh install must reach the app.
`AlbusUITests` covers exactly this path and is the fastest check:

```
xcodebuild test -scheme Albus -only-testing:AlbusUITests
```

**Until it is on**, account farming stays bounded by the free accounts' fuses
(100 AI calls/hour and US$1/day, which paying students do not share) plus the
per-IP sign-up limit of 10/hour. The residual risk is cost, not data — see
`docs/security-model.md` § 4 and § 5.


---

## Notifications — what only works on a signed build

Albus speaks first: a morning brief, a nudge when a block starts, a deadline
ladder, and the one no other planner can send — **your plan stopped fitting**,
straight off `ScheduleResult.unplaceable`.

All of the policy lives in `AlbusCore/Notifications/` and imports no
`UserNotifications`, so quiet hours, the daily cap, the 64-slot budget and DST
are all answered by `swift test` with no simulator. The app half is a
namespace-scoped diff against what iOS actually holds.

**Two things worth knowing before changing any of it.**

*`albus.session.*` is not ours.* The focus timer owns that namespace, and a
rebuild that called `removeAllPendingNotificationRequests` would delete a
running timer's only alert — `reschedule` can fire mid-session. The rebuild only
ever touches `albus.plan.*`, checked in both the client and the coordinator.

*The 64-slot ceiling is real for Pro only.* iOS keeps the 64 soonest-firing
pending notifications and silently discards the rest. Free caps at five active
assignments and Plus at ten, so neither approaches it; Pro is uncapped. The
planner allocates to 48 explicitly and logs anything it drops.

### Blocked on a Team ID

`ALBUS_SIGNED_BUILD` in `App/Config.xcconfig` gates Time Sensitive delivery on
overdue and plan-broken warnings, the same way `TURNSTILE_SITE_KEY` gates the
CAPTCHA. Set it to `YES` in the same change that sets `DEVELOPMENT_TEAM`.

Being honest about what that flag buys: setting `.timeSensitive` **without** the
entitlement is *ignored* by iOS rather than rejected, so leaving it `NO` costs
nothing today. It is there so the capability is legible and so switching it on is
one line rather than an investigation.

**Live Activities** (a Dynamic Island countdown for a focus session) and
**Communication Notifications** (Albus rendered as a correspondent rather than an
app) both need a Team ID *plus* a new extension target. They are the natural v2.

### What no test can cover here

Actual delivery, lock-screen truncation and the attachment at true scale need a
device. **DST cannot be meaningfully verified by hand at all** — `simctl` cannot
move the clock usefully — so `NotificationPlannerTests` is the real coverage for
it, not a manual pass.

To see what is actually queued in the simulator:

```bash
D=~/Library/Developer/CoreSimulator/Devices/<udid>/data/Library/UserNotifications
strings "$(ls -t $(find "$D" -name PendingNotifications.plist) | head -1)" | grep -o "albus\.plan\.[a-zA-Z0-9._-]*" | sort -u
```

That is how the last two copy bugs were found, after every unit test was green.


---

## Albus Grader — the one number, and the one that was wrong

Marking is the most expensive call the app makes, so three things about it are
worth knowing before changing any of it.

**A grade is not a mark total.** `overall_marks / total_marks` is the rubric's
arithmetic — an MYP rubric totals 32, and "0/32" is not what a course writes at
the top of the page. `grade_label` is the grade, in the scale the student names
before anything is marked, and it is the reason the flow asks *how does your
course mark this?* at all. A blind reading is structurally incapable of carrying
one: the normaliser strips it after the model has spoken, and the client refuses
it a second time.

**A reservation is not a spend.** The usage slot is taken before the model runs,
because that is what stops ten parallel requests each seeing zero used. The
refund on failure is a fast path, not the guarantee — it needs the function to
survive long enough to run. So `grading_spend_count` asks whether anything was
actually bought (tokens billed, or a grading pointing at the row) and lets
anything younger than fifteen minutes count as in flight. A reservation the
runtime killed ages out by itself.

**The meter and the gate must count the same way.** They did not, and the screen
showed "3 left this week" directly above "that's this week's markings used",
because the limit that refuses a free student is a daily cap of two.
`grading_allowance()` returns every window and the client names whichever binds,
breaking ties toward the *longer* one — at zero on both the hour and the day,
promising one back in an hour is a promise the daily cap will not keep.

### What no unit test caught

Every defect in this feature so far has been green in the suite and obvious in
the output. Read real responses:

```bash
deno test supabase/functions/_tests/          # the prompt, the normaliser, the signals
xcodebuild test -scheme Albus -only-testing:AlbusUITests/GraderUITests
```

The UI tests drive the real backend. `testGraderMeterNamesTheWindowThatActuallyBinds`
is the regression test for the meter — it asserts the shape the plan call
returns, which the client decodes by hand and which has changed twice.

Marking is deliberately *not* exercised end to end there: a grading is a real
Opus call, and it is now a paid feature — a Free account gets `PLAN_UPGRADE_REQUIRED`
before any model runs.


---

## Plans — Free, Plus, Pro

| | Free (€0) | Plus (€9.99/mo) | Pro (€17.99/mo) |
|---|---|---|---|
| Active tasks | 5 | 10 | unlimited |
| AI step plans | 5 / week | unlimited | unlimited |
| Albus Grader | — | 2 / week | 5 / week |
| Saved rubrics | 3 | 5 | unlimited |
| Tools | basic | expanded | all + curriculum intelligence |

**The app enforces none of this**, and that is the design. `public.plans` is the
single source of truth; the gate, the meter and the paywall all read it, and
every refusal happens inside a Postgres transaction under a per-user lock.
`EntitlementService` exists to draw the right screen. A tampered value there
buys a nicer paywall and nothing else.

### The one convention to know before touching any of it

**`nil` is unlimited. `0` is not included.**

This reverses what the code used to say. Before three tiers, `limit == 0` meant
"no ceiling" — it was how Plus was expressed. Free now genuinely gets *zero*
gradings, so the old reading would have shown every free student unlimited
marking. `Allowance.isIncluded` is checked before `remaining` everywhere, and
`PlanAllowanceTests` is what keeps it that way.

The two exhausted-looking states are different products:

| | what it means | what the student is shown |
|---|---|---|
| `limit == 0` | not on this plan | a price |
| `remaining == 0` | bought, and used up | a date |

Showing the second to somebody in the first state promises a Monday that never
comes. Showing the first to somebody in the second sells a Plus subscriber Plus.

### The device header

`DeviceSignal` adds `x-albus-device` to the three function calls. It is
`identifierForVendor` — per-vendor, resets on delete, not a hardware serial —
and the server hashes it with a secret we do not ship before storing the digest.
Withholding it costs a student nothing: a missing signal cannot escalate an
account on its own. See `docs/security-model.md` § 6.

### Verifying it

```bash
supabase test db --local                    # 92 policy and financial-safety checks
scripts/security-concurrency-local.sh       # real multi-connection limit races
xcodebuild test -scheme Albus -only-testing:AlbusTests
```

The one thing neither can check is concurrency — a single connection cannot
demonstrate a race, and will happily report a race-prone gate as clean. That
check uses twelve independent Postgres connections and requires exactly one
winner at the final grading, active-task, and rubric slot.

## Deleting an account — the answer that never arrives

`delete_my_account()` takes no arguments and reads `auth.uid()`, so a student
can only ever delete themselves. It is idempotent: asked twice, the second call
deletes nothing and still succeeds.

The hard case is not the server. It is a request that **commits and whose
answer is lost**, because from the phone that is indistinguishable from a
request that never arrived. Three rules settle it:

1. **Ask before erasing anything.** `albus.accountDeletion.requested` is
   written *before* the call, and `albus.accountDeletion.pendingCleanup` only
   after the server confirms. The first says a question is outstanding; only
   the second erases work.
2. **A refused credential is the answer.** An anonymous account has no password
   and no second way in, so once its refresh token is refused, nothing on this
   device can reach it again. A refusal plus an outstanding request means the
   deletion happened, and `adoptLostDeletion` finishes it at launch.
3. **No signal is never evidence.** `SessionService.credentialRejected` stays
   false for a `URLError`, so a phone in a tunnel erases nothing. Reading a
   dropped connection as "deleted" would destroy the work of anyone who tapped
   Delete underground and changed their mind.

**What this prevents.** Without rule 2 the student was asked to try again
forever — the access token expires after about an hour and the refresh token
died with the account, so every later attempt is refused. Worse, on the next
cold launch the session could not be restored, so the app offered onboarding
while every assignment, rubric and mark they had asked Albus to delete was
still in the store, ready to be adopted by the new account. Four tests in
`AccountDeletionTests` cover exactly these branches.


## UI tests — two kinds, and only one is free

`AlbusUITests` is split by what a test costs, not by what it covers.

**Free, and in CI.** `PaywallUITests` and `EntitlementRefreshUITests` launch
already signed in, with the plan forced:

```
-albus.debug.assumeSignedIn          a presentation-only session, no credential
-albus.profile.onboarded YES         skip onboarding
-albus.debug.forcePlan free|plus|pro synthesise the plan `my_plan()` would return
-albus.debug.noPurchases             no RevenueCat
-albus.debug.openSettings            start on Settings
-albus.debug.skipNotificationPrompt  XCUITest suppresses the system prompt,
                                     so the request would never return
```

The five `-albus.debug.*` switches are compiled out of Release: four sit inside
`#if DEBUG`, and `noPurchases` is read only when `isDebug`, which `#if DEBUG`
sets. **`-albus.profile.onboarded` is not a switch at all** — it is the ordinary
`UserDefaults` key `Preferences` reads, set through the launch-argument domain,
so it works in any build. That is harmless: App Store users cannot pass launch
arguments, and it only skips the onboarding screens. None of them grants
anything either way — every limit is enforced again in the database, in the
same transaction as the write. A forced plan buys a nicer paywall and nothing
else.

**Costly, and skipped by name in CI.** `GraderUITests`, `CoreLoopUITests`,
`PopupChromeUITests` and `SettingsUITests` call `OnboardingPath.reachApp`,
which creates a real account on the production project and spends a real Claude
call. Run them deliberately, against a backend you meant to touch. Never run
one to reproduce a UI failure — reach the screen with the flags above and read
`app.debugDescription` instead.

### The trap that made the paywall untestable

The moon scene's twinkle and bob are `repeatForever`, and they used to start
even on the settled panel and with Reduce Motion on. A view that never stops
animating means **the app never reports itself idle**, so XCUITest waits out
its idle timeout before every interaction: one paywall test took 123 seconds
and its five-second waits expired against a screen that was already correct.
Starting them only when motion is wanted fixed both — the accessibility
promise, and the test — and the same three tests now run in about 20 seconds
each.

If a UI test on an animated screen fails on a wait rather than on an
assertion, suspect a `repeatForever` before you suspect the screen.
