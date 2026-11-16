# Pre-submission audit, November 2026

Written 14–16 November 2026 by Claude Code (Claude Fable 5.2, finished by
Claude Opus 5.5), before Albus is submitted to Apple on 23 November.

Nobody had read Albus end to end as it stands. Each of about 50 pull requests
was reviewed on its own. This audit reads the app, the functions and the
database together, and looks for what would:

1. get the app rejected by App Review;
2. take a student's money without giving them what they paid for, or give paid
   features away;
3. lose, leak or wrongly keep a student's data, or break sign-in, account
   switching or deletion;
4. spend the AI budget while the student gets nothing;
5. make the app, the website or the privacy policy say something the code
   doesn't do.

## How to read this

- **What was read.** `main` at `1509386`, together with the four pull requests
  that were ready to merge when the audit ran (#48 app wording, #49 reminder
  phrase, #50 website rubrics, #51 tool names). The second pass (16 November)
  read the same with the audit's own fixes merged on top (#52, #53, #54). Line
  numbers are on `main` at `1509386`.
- **Confirmed** means the failure follows from the code as read, or was seen
  in real output. **Plausible** means the mechanism is there but how often it
  happens, or whether it happens on a real phone, was not observed.
- **Nothing here was tested against the live server, the App Store or
  RevenueCat.** No sign-in, purchase or paid AI call was made. Findings that
  depend on those say so.
- Model facts (which models reason by default, how that counts toward
  `max_tokens`, prices, cache minimums) come from Anthropic's Claude API
  reference bundled with Claude Code, dated 3 November 2026, not from memory.

## Summary

| # | Finding | Status | Matters for | Action |
|---|---|---|---|---|
| A1 | A rubric AI plan can be cut off by the model's hidden reasoning; the call is paid for and the student gets the phone's plan | Confirmed mechanism, frequency unknown | 4, 2 | Fixed in #52; needs a migration and a function deploy |
| A2 | The daily AI budget floor allows about five rubric markings a day across every paying, trial and tester account | Confirmed | 2, 1 | Owner decision |
| A3 | "Albus is at capacity" reaches the student as "couldn't finish marking that. Try again" | Confirmed | 2 | Fixed in #54 |
| A4 | Reminders say "1 assignments are still open" and "1 steps can't be placed" | Confirmed, seen in real output | 5 | Fixed in #53 |
| A5 | Thirty reminder lines carry `**bold**` markers that the lock screen shows as asterisks | Plausible (not seen on a phone) | 5 | Fixed in #53 |
| A6 | A purchase made while `REVENUECAT_APP_IDS` is unset is retried for a few hours only | Confirmed by reading | 2 | Order of the owner's steps |
| A7 | Deleting an account does not revoke Sign in with Apple until the Apple secrets are set | Confirmed by reading | 1, 3 | Owner step before submission |
| A8 | A fourth rubric on Free is refused by the server, and the app says only "Couldn't sync this rubric" | Confirmed | 5, 2 | Owner decision on wording |
| A9 | After a second account takes over a phone that held another's tasks, the app can show Free until the next refresh | Plausible | 3 | After launch |
| A10 | The privacy policy's sentence about Apple being unreachable has the gap Greptile found in the app | Confirmed | 5 | Fixed in #58 |
| A11 | Four tool tiles opened sites that have closed, and two opened addresses that do not answer | Confirmed in a browser | 1, 5 | Fixed in #51 |
| A12 | The first plan in onboarding waits for the AI answer with no upper limit short of the network timeout | Confirmed by reading | — | After launch |
| A13 | The Grader's "Take a photo" row opens the photo library, not the camera | Confirmed by reading | 1, 5 | One-line app fix, after #48 |
| A14 | The privacy policy says study-time records "contain no text"; each holds the subject's name | Confirmed by reading | 5 | Fixed in #58 |
| A15 | The website's home page says Albus "marks your work" without saying marking is paid | Confirmed | 5 | Fixed in #58 |
| A16 | A marking that finishes after the student signs out is used but not kept on the phone | Confirmed by reading | 2 | After launch; resubmitting is free |
| A17 | The plan prompt still introduces Albus as a planner "for IB, AP and university students" | Confirmed | — | After launch, with a measured comparison |
| A18 | Prompt caching can never engage for the plans Haiku 4.5 writes | Confirmed from the API reference | 4 | After launch |
| A19 | "1 step today. I've arranged them." | Confirmed by reading | 5 | After launch |
| A20 | Five tool tiles land on a different site from the one they name, and USGS did not load on 16 November | Confirmed by following each link | 5 | After launch; recheck USGS on the final build |

Sign-in, purchase, restore and the first plan were read first. Nothing found in
them blocks the TestFlight build. The one fix from that pass, A1, is on the
server. The second pass read marking, task sync, account deletion and
reminders; its fixes are #53 and #54.

Nothing found would get the app rejected on its own, provided the owner does
three things before submission: run `scripts/set-apple-secrets.sh` (A7), set
`REVENUECAT_APP_IDS` before anyone buys (A6), and decide A2, because a
reviewer who tries marking after the day's budget is spent sees "at
capacity".

## Findings

### A1. A rubric AI plan can be cut off by the model's hidden reasoning

- **Where.** `supabase/functions/_shared/anthropic.ts:75` (`max_tokens: 2000`,
  and no check of `stop_reason` other than `refusal`);
  `supabase/functions/_shared/prompt.ts:48` (`MODEL_RUBRIC = "claude-sonnet-5"`).
- **What happens.** A student on any plan adds a task with a rubric attached.
  The server asks Sonnet 5 for the plan and sends no `thinking` setting. Sonnet
  5 reasons before answering by default. That reasoning is not returned, but it
  is billed as output and spent from `max_tokens`. With 2,000 for everything, a
  plan can run out partway through its JSON (`MALFORMED_RESPONSE`) or before
  any of it (`EMPTY_RESPONSE`). The app keeps the phone's own plan and says
  "Albus couldn't write a step-by-step plan right now".
- **Status.** Confirmed mechanism. How often it happens is unknown: no paid
  call was made, and the production ledger was not read. A comment at
  `anthropic.ts:164` records marking being cut off at 4,000 tokens on a
  three-criterion rubric whose visible answer is about 2,750 by the code's own
  estimate, which fits hidden reasoning of over a thousand tokens.
- **Impact.** The owner pays up to about US$0.02 plus input for each failed
  call. The student's weekly AI plans are not used up (a failed call is not
  counted), but they don't get the rubric plan. The onboarding plan has no
  rubric, uses Haiku 4.5, which does not reason by default, and is not affected.
- **Fix.** #52: the plan call allows 5,000, and a cut-off is reported and
  logged as `RESPONSE_TRUNCATED`. Before raising the cap, the reservation was
  checked: a plan call is admitted against `private.ai_reservation_cost`, which
  was sized for 2,000. Migration `20261115120000` raises the Sonnet plan
  reservation from US$0.06 to US$0.125, enough for the largest prompt the app
  can send (measured by `prompt_test.ts`) plus 5,000 output tokens, and
  `plan_reservation_test.sql` fails if the two drift apart. It needs the
  migration applied and `breakdown` and `grade` deployed (they share
  `_shared/anthropic.ts`), which `scripts/deploy-plan-cutoff-2026-11-16.sh`
  does (#57), after #52 is merged.
- **What it costs.** A plan that fitted before is produced and billed exactly
  as before; the model never sees `max_tokens`. Admission is stricter: a rubric
  plan now needs US$0.125 of room in the pool instead of US$0.06.
- **To measure after it is deployed.** Count `ai_usage` rows with
  `kind = 'breakdown'` by `failure_code` over a week. `RESPONSE_TRUNCATED`
  should be rare; if it is not, the cap or the reasoning setting needs a
  measured change.

### A2. The daily AI budget floor allows about five rubric markings a day in total

- **Where.** `supabase/migrations/20260915120100_spending_cap_counts_real_money.sql:240`
  (US$1 a day, US$1 an hour); `20260917130000_payments_backend.sql:487`
  (`private.ai_pool_budget`: the paid pool is the larger of that floor and 25%
  of the last 30 days' *Production* proceeds, divided by 30);
  `20260830104329_production_financial_safety.sql:87` (a rubric marking on Opus
  5 reserves US$0.45); `20260925170000_subscription_ordering.sql:611` (a call is
  refused when the day's spending plus the reservation would pass the budget).
- **What happens.** Free accounts share one US$1-a-day pool. Everyone on Plus
  or Pro, including students in their free trial, TestFlight testers and App
  Review (all of whom buy in the sandbox, which adds no proceeds), shares
  another. A rubric marking costs roughly US$0.10 to US$0.15 in real tokens. A
  new one is admitted only while the day's spending is at most US$0.55, so the
  sixth marking of the day, by anyone, is refused with
  `GLOBAL_CAPACITY_REACHED`. Each subscriber adds only about US$0.06 a day to
  the pool, so the floor governs until there are roughly 17 paying subscribers.
- **Status.** Confirmed by reading. The per-marking cost is an estimate
  (about 5,000 input and 4,000 output tokens on Opus 5 at US$5 and US$25 per
  million); the real figure is in `ai_usage.actual_cost_microusd`.
- **Impact.** On launch day, students who have just started a trial to try
  marking can be told to try again later for the rest of the day. During
  testing, three or four testers trying marking on the same day use it up. If
  the pool is spent when Apple's reviewer tries marking, the reviewer sees a
  failure.
- **Not a code defect.** The floors were chosen so that the worst month stays
  near the owner's US$65 limit at Anthropic. It is the owner's decision; see
  "Decisions for the owner".

### A3. "At capacity" is shown as an ordinary failure

- **Where.** `ios/App/Albus/Services/GradingService.swift:392` maps
  `GLOBAL_CAPACITY_REACHED` to `.unavailable`: "Albus couldn't finish marking
  that. Try again with the same work and settings." The server's own message
  (`supabase/functions/_shared/http.ts:187`, "Albus is at capacity right now.
  Try again shortly.") is discarded.
- **What happens.** With A2, a paying student is told to try again, does, and
  fails again, all day, with nothing to say it is not their work or their
  connection.
- **Status.** Confirmed by reading.
- **Fix.** #54: its own message, "Albus is at capacity right now, so this
  wasn't marked and none of your markings was used. Try again later." True:
  the refusal comes before anything is reserved. It does not open the plans,
  because paying does not buy capacity. Wording only.

### A4. Reminders use a plural for one

- **Where.** `ios/AlbusCore/Sources/AlbusCore/Notifications/Copy/Corpus+Engagement.swift:26`,
  `:36`, `:63` (`{count} assignments …`);
  `Corpus+Deadline.swift:165`, `:168`, `:177`, `:184` (`{count} steps …`).
- **What happens.** A student with one open assignment who has not opened
  Albus for three days gets "It's been a few days — 1 assignments are still
  open." A plan with one step that no longer fits says "1 steps can't be
  scheduled before their deadline."
- **Status.** Confirmed, by printing the reminders a realistic week produces.
  A green test suite did not catch it.
- **Fix.** #53: a count of one is not offered to the reminder lines, so the
  planner picks a line that states no number. Two new plain lines make sure
  the quiet-app reminders always have one to pick. No existing line was
  edited.

### A5. Reminder lines carry bold markers

- **Where.** Thirty lines in `Corpus.swift` and `Corpus+Deadline.swift`
  contain `**{step}**`; `ios/App/Albus/Services/NotificationScheduler.swift:179`
  copies the text into the notification unchanged.
- **What happens.** iOS shows notification text as plain text, so a reminder
  would read "History essay is due tomorrow. \*\*Outline the method\*\* is where
  you start."
- **Status.** Plausible. The simulator check failed (notifications are
  switched off for Albus on the test simulator), so it was not seen.
- **Fix.** #53 strips the markers from the template before the facts are
  filled in, so a student's own asterisks ("Evaluate 2\*\*3") survive. Safe
  whether or not iOS would have shown them.

### A6. A purchase made before the webhook is fully set up is not retried for long

- **Where.** `supabase/functions/revenuecat-webhook/index.ts:215`: with
  `REVENUECAT_APP_IDS` unset, every purchase event is answered 503.
- **What happens.** RevenueCat retries a failed delivery a handful of times
  over a few hours, then stops. A purchase, including a sandbox one, made while
  the secret is unset, and not followed by the secret being set within that
  time, never reaches the server on its own. The app says "Payment done. Albus
  hasn't confirmed Plus yet."
- **Status.** Confirmed by reading; RevenueCat's retry schedule is from its
  documentation as recalled, not re-checked.
- **Action.** Set `REVENUECAT_APP_IDS` (Part 3 of the owner's steps) before
  anyone buys, including in TestFlight. For an event that was missed, resend it
  from RevenueCat's dashboard.

### A7. Sign in with Apple is not revoked on deletion until the secrets are set

- **Where.** `supabase/functions/delete-account/handler.ts:63`: with the four
  `APPLE_*` secrets unset, the function logs `apple_revoke_unconfigured` and
  deletes the account without asking Apple to revoke.
- **Impact.** Apple requires apps that offer Sign in with Apple to revoke its
  tokens when an account is deleted. A reviewer who deletes their test account
  cannot see the difference, but the requirement is not met until the owner
  runs `scripts/set-apple-secrets.sh`.
- **Status.** Confirmed by reading. The deletion itself still works.

### A8. A rubric over the plan's number fails without saying why

- **Where.** `ios/App/Albus/Services/RubricService.swift:45`; the server's
  `RUBRIC_PLAN_LIMIT` (`supabase/functions/_shared/http.ts:60`) is thrown away
  at `RubricService.swift` in the generic `catch`;
  `supabase/functions/breakdown/index.ts:138`.
- **What happens.** A Free student saves a fourth rubric. It is saved on the
  phone, the server refuses the copy, and the app says "Couldn't sync this
  rubric. It's saved on your phone." A task made with that rubric gets the
  phone's plan ("Albus couldn't write a step-by-step plan right now"), and
  marking against it says "Pick a rubric to mark this against."
- **Status.** Confirmed by reading. How to word a plan limit is the owner's
  open decision.

### A9. After another account takes over a phone, the plan can show Free until refreshed

- **Where.** `ios/App/Albus/AlbusApp.swift:185` (`replaceAccountServices`
  makes a new `EntitlementService`, which starts at Free);
  `ios/App/Albus/Shell/RootView.swift:53` (the plan is read when the signed-in
  account changes, not when the services are replaced);
  `ios/App/Albus/Services/LocalAccount.swift:97`.
- **What happens.** Account B signs in on a phone holding account A's tasks
  and chooses "Remove them and continue". The services are replaced after B's
  plan was read, and nothing reads it again until Settings or the Grader opens,
  a task is finished, or the app returns from the background. Until then the
  paywall shows B as Free.
- **Status.** Plausible: it follows from the code, but needs two Apple IDs on
  one phone to see, which could not be done here. It heals on its own.

### A10. The privacy policy's sentence about Apple

- **Where.** `website/privacy/index.html:150`: "If Apple can't be reached, your
  account is still deleted".
- **What is true.** The phone needs Apple's confirmation before it sends any
  deletion request. Only the server's later call to Apple is best effort.
- **Status.** Confirmed; the same gap Greptile found in the app's sentence on
  #48.

### A11. Tool tiles that led nowhere

Fixed in #51. Open Access Button shut down on 18 November 2025,
typewritermode.com no longer exists, Cram retired on 9 November 2026 and
Socratic now lands on a Google Search page. `usgs.gov` and `noisli.com` do not
answer without `www.`.

### A12. Onboarding waits for the AI plan

- **Where.** `ios/App/Albus/Screens/OnboardingFlow.swift:246`.
- **What happens.** "Building your plan" stays until the server answers or the
  request fails. The phone's own plan exists from the first moment, but the
  screen does not move on. On a stalled connection that can be up to the
  180-second request timeout.
- **Status.** Confirmed by reading. Normally the answer takes a few seconds.

### A13. "Take a photo" opens the photo library

- **Where.** `ios/App/Albus/Screens/GraderScreen.swift:372` labels the row
  "Take a photo", with a camera icon; `:181` opens `photosPicker`, which is the
  photo library. There is no camera path in the app.
- **What happens.** A student, or a reviewer, taps "Take a photo" expecting the
  camera and gets their photo library. App Review checks that a control does
  what it says.
- **Status.** Confirmed by reading.
- **Fix.** One string: "Choose a photo" (and the icon `photo`). It waits for
  #48 to merge, which edits the lines around it. The App Store description
  already says "choose a photo".

### A14. "These records contain no text"

- **Where.** `website/privacy/index.html:56`, about how long each study step
  took. `CompletionRecord.subjectCode` (`ios/App/Albus/Models/LocalStore.swift:272`)
  holds the subject's name as the student typed it, filled from
  `course.displayName` (`PlanBridge.swift:41`).
- **What is true.** The records hold the subject's name and the kind of task,
  and they never leave the phone.
- **Status.** Confirmed by reading. Small, but the policy is where a sentence
  must be exact.
- **Fix.** Website: "These records hold the subject and the kind of task, not
  anything you wrote, and stay on your phone."

### A15. The home page says Albus marks your work

- **Where.** `website/index.html:15`: "and marks your work, against your mark
  scheme if you give it one."
- **What is true.** Marking is on Plus and Pro only. The App Store description
  says so; the home page does not.
- **Status.** Confirmed.
- **Fix.** Website: "and, on Plus and Pro, marks your work".

### A16. A marking that finishes after sign-out is not kept on the phone

- **Where.** `ios/App/Albus/Services/MarkingCoordinator.swift` (`mayStore`);
  `supabase/functions/grade/index.ts:205–235` and `:252`.
- **What happens.** A student sends work for marking and signs out before it
  comes back. The server finishes and stores the result, and the marking is
  counted. The phone, now signed out, rightly refuses to file it under no
  account, so the student does not see it.
- **What limits it.** When they sign back in and send the same work with the
  same rubric and settings, the server finds the stored result by its
  fingerprint and returns it before reserving anything, so it costs nothing.
  Nothing tells them that.
- **Status.** Confirmed by reading. Rare: signing out mid-marking is unusual.
- **After launch.** Show past markings from the server in the history screen.

### A17. The plan prompt still says "IB, AP and university students"

- **Where.** `supabase/functions/_shared/prompt.ts:107`, the first line of
  every plan prompt.
- **What happens.** Albus stopped being an IB app in September. The model is
  told its students are IB, AP and university students, which may tilt step
  wording toward those systems for a school student elsewhere.
- **Status.** Confirmed that the text is there. Whether it changes any plan was
  not observed: no paid call was made.
- **After launch.** Change it with a side-by-side comparison of real plans,
  not before: a prompt change is a behaviour change that only paid calls can
  check.

### A18. Plans written by Haiku 4.5 can never use prompt caching

- **Where.** `supabase/functions/_shared/anthropic.ts:117` marks the system
  prompt for caching; for a plan without a rubric that prompt is `VOICE`
  alone, about 3,700 characters, roughly 900 tokens.
- **Fact.** Haiku 4.5 caches nothing shorter than 4,096 tokens (Anthropic's
  API reference, 3 November 2026). The comment at `anthropic.ts:115` says
  ~1,024, which is right for Sonnet 5 only.
- **Impact.** None today: an uncached prompt costs nothing extra. It only means
  no saving. Recorded so nobody expects one.

### A19. "1 step today. I've arranged them."

- **Where.** `ios/AlbusCore/Sources/AlbusCore/Notifications/Copy/Corpus.swift:58`
  (`brief.busy.03`). The busy lines are chosen by how full the day is
  (`Scheduler.swift:341`, 55% of the day's study time), not by the number of
  steps, so one long step can fill a short day.
- **Status.** Confirmed by reading. Cosmetic.
- **After launch.** Give the line a minimum step count, or reword it.

### A20. Tool tiles that land somewhere else

Every tool's address was followed on 16 November, with an iPhone Safari user
agent:

| Tile | Lands on |
| --- | --- |
| Eurostat (`ec.europa.eu`) | The European Commission's language picker. `ec.europa.eu/eurostat` works. |
| Climate Data (`climate.gov`) | NOAA's climate page. |
| Quizizz (`quizizz.com`) | `wayground.com`, its new name. |
| Sleepyti.me (`sleepyti.me`) | A sleep calculator on `sleepopolis.com`. |
| Google Slides (`slides.google.com`) | Google Workspace's product page, not the editor. |
| USGS (`www.usgs.gov`) | Did not load, in curl or in Chrome, for over a minute. It loaded on 15 November. |

Others moved within the same product (ChatGPT, Notion, NotebookLM, OneNote,
Streaks, XMind, Water Reminder) and open the right thing. About 40 sites
refuse a script with a 403 but open in a browser; Saturday's browser check
covered the closed ones (A11). Google Calendar and Docs ask the student to
sign in, which is expected.

- **After launch.** Fix the six addresses or names in `scripts/tools/gen.py`
  and regenerate. Check USGS again on the final build; if it is still down,
  remove its tile before submission.

## Read and found sound

Listed so the next reader knows these were looked at, not skipped.

- **Sign-in.** `SessionService`, `SignInScreen`, `LocalAccount`,
  `AccountSwitchScreen`: a stored session opens at once and is renewed in the
  background; a refused credential signs out; another account's tasks are never
  shown without the student choosing.
- **Purchase and restore.** `PurchaseService`, `PurchaseFlow`, the paywall: a
  purchase is only possible once RevenueCat knows the signed-in account; the
  plan shown always comes from the server; restore, Terms and Privacy are on
  the paywall.
- **Webhook.** Authorisation, signature, app allow-list, store check, sandbox
  switch, and the four product ids mapped in
  `20260917130000_payments_backend.sql:52`.
- **Allowance.** A failed AI call is not counted against the student's weekly
  plans or markings (`public.ai_spend_count`), and the real token cost is
  recorded either way (`public.finalize_ai_usage`).
- **The phone's own plan.** Printed for ten realistic tasks; the sessions add
  up to the budget and none is longer than a sitting.
- **Marking's output cap.** 8,000 tokens, left alone. Opus 5 reasons by
  default too, but marking already reports a cut-off as `RESPONSE_TRUNCATED`
  and does not use up a marking, the student is told "There was too much to
  say about that in one go", and its reservation (US$0.45) already covers
  8,000 output tokens. Raising it would also push against Supabase's 150-second
  limit for a function.
- **Account deletion.** `delete_my_account` removes the `auth.users` row and
  relies on foreign keys. All 18 references to an account are `on delete
  cascade` or `set null`; the only references without a rule point at fixed
  tables (plans, curricula, webhook events), so nothing can block a deletion.
  `account_erasure_test.sql` finds every table in `public` and `private` by
  itself and checks each one holds no trace of the deleted account apart from
  the disclosed payment records. It passed on 15 November on a database
  rebuilt from every migration.
- **What that test does not cover.** It puts the account's rows only into the
  tables its fixture names. A table added later, with no fixture rows, passes
  the check trivially, even if deletion would leave its rows behind. Today
  that gap is closed by the foreign keys above, but only for a table whose
  account column references `auth.users`. So every new table that holds a
  student's data needs a foreign key with `on delete cascade` or `set null`,
  and rows in the erasure test's fixture. (Found by Greptile on #56.)
- **Task sync.** `sync_my_assignments` and `release_my_other_assignments`
  (`20261006120000`) act only on the caller's rows, take the same lock as the
  task-limit trigger, refuse more than 500 ids, and a reopen still meets the
  plan's cap. The phone sends at most 500 of each
  (`PlanCoordinator.serverListLimit`).
- **Debug switches.** Every `-albus.debug.*` launch argument is inside
  `#if DEBUG`, so none exists in the release build.
- **Privacy manifest.** The built app's manifest matches the source, tracking
  is false, and RevenueCat's own manifest is bundled
  (`scripts/verify-app-privacy.py`, 16 November). See
  `docs/app-store/verification.md`.

## Decisions for the owner

Each with a recommendation. None is decided in code.

1. **The AI budget floor (A2).** Today the paid pool allows about five rubric
   markings a day between everyone, testers and App Review included. If it is
   spent when the reviewer tries marking, the reviewer sees "Albus is at
   capacity" and may reject the app as not working. One setting,
   `ai_budget_per_day_microusd`, is the daily floor for both pools
   (`private.ai_pool_budget`), so raising it raises the free pool's budget
   too. **Recommendation:** raise it from US$1 to US$2 for the review window
   only, from submission until Apple approves (usually a few days), then set
   it back. Worst case that is US$2 a day more, both pools spent in full,
   which a handful of testers and one reviewer will not come near. Each
   marking still needs US$0.45 of room, so US$2 allows roughly a dozen a day in
   total and the hourly floor (US$1) about four an hour. A floor for the paid
   pool alone would need a code change. Changing the value is a production
   write, so it would come as a script for you to run, and another to set it
   back.
2. **Four tools removed and three renamed (#51).** This goes beyond what was
   asked, so it is yours to accept. Removed: Sci-Hub Alternatives (the name it
   was to get, Open Access Button, belongs to a service that shut down in
   2025), Hemingway Mode (its site, typewritermode.com, is gone), Cram
   (retired on 9 November) and Socratic (now lands on Google Search). Renamed
   to what they open: Hemingway Grade to Readability Formulas, Library Genesis
   Info to Open Library, IB Documents to IB official site. **Recommendation:**
   accept; 221 tools remain.
3. **How the rubric limit is described (A8).** The website now says "Synced
   rubrics: 3, 5, Unlimited" with a sentence on what syncing means (#50), and
   the app's paywall says the same. When the limit is reached the app still
   only says "Couldn't sync this rubric." **Recommendation:** keep the
   current wording for launch, and after launch make that message say the plan
   syncs 3 (or 5) and that AI plans and marking can't use this one.
4. **The Plus card's badge.** It says "WITH MARKING" (`PaywallScreen.swift:115`).
   Pro has marking too, so on Plus alone the badge can read as if Pro does
   not. **Recommendation:** remove it for launch. "RECOMMENDED" would be the
   alternative; it says nothing false.
5. **EU trader status.** App Store Connect asks whether the seller is a trader
   under the EU's Digital Services Act. A trader's address, phone and email
   are shown on the EU App Store page. Albus sells subscriptions, and the
   developer account is your father's individual membership, so the details
   shown would be his. **Recommendation:** decide this with him before
   submission, and take advice if unsure. This document does not suggest an
   answer.
6. **Supabase Pro at US$25 a month.** On the free plan there are no daily
   backups you can restore; Pro keeps seven days of them (Supabase's backups
   guide). The free plan also pauses a project after a week of low activity,
   though a few requests a day prevent that, so with testers and a live app it
   is unlikely. Losing the database after launch would lose every student's
   account, subscription link and saved rubrics, with nothing to restore.
   **Recommendation:** upgrade in the week of submission, for the backups.

## After launch

In rough order of value.

1. **Measure A1.** After #52 is deployed, count `ai_usage` rows for plans by
   `failure_code` for a week. `RESPONSE_TRUNCATED` should be rare.
2. **Fix the tool tiles in A20** and check USGS.
3. **Rubric-limit message (A8)**, once the wording is decided.
4. **Show server-side markings in the history (A16).**
5. **Plan prompt (A17)**: drop "IB, AP", compared side by side on real plans.
6. **Entitlement refresh after an account switch (A9).**
7. **Let onboarding move on after a few seconds (A12)**, since the phone's plan
   is already there.
8. **Reminder line A19.**

### Model prices, checked 16 November 2026

From Anthropic's API reference bundled with Claude Code (prices dated 3
November 2026), per million tokens, input / output:

| Model | Used for | Price | Newer model in the same line |
| --- | --- | --- | --- |
| Claude Haiku 4.5 | Plans without a rubric | US$1 / US$5 | Claude Haiku 5.5: US$0.10 / US$0.50 (prompts under 100,000 tokens) |
| Claude Sonnet 5 | Plans with a rubric, marking without a rubric | US$2 / US$10 | Claude Sonnet 5.5: same price, cheaper cache reads |
| Claude Opus 5 | Marking against a rubric | US$5 / US$25 | Claude Opus 5.5: US$4 / US$20 |

Not before launch, because each move changes how the model behaves and only
paid calls can check it. After launch:

- **Opus 5 to Opus 5.5 for marking** would cut its price by a fifth. Opus 5.5
  cannot switch reasoning off and reasons at a lower default effort, so set
  the effort explicitly, re-derive the marking reservation from the new price,
  and compare markings side by side.
- **Haiku 4.5 to Haiku 5.5 for plans** would cut their price about tenfold,
  and Haiku 5.5 caches prompts from 512 tokens, so A18 would go away. But
  Haiku 5.5 reasons by default, unlike Haiku 4.5, so it needs the same room in
  `max_tokens` and the reservation as #52 gave Sonnet.
- **Sonnet 5 to Sonnet 5.5** saves little, since the price is the same.

Every move needs `private.ai_reservation_cost` and `private.ai_metered_cost`
updated for the new model in the same migration, or the gate will refuse the
call.
