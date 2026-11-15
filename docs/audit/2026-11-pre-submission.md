# Pre-submission audit, November 2026

Written 14–15 November 2026 by Claude Code (Claude Fable 5.2), before Albus is
submitted to Apple on 23 November.

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
  phrase, #50 website rubrics, #51 tool names). Line numbers are on `main` at
  `1509386`.
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
| A1 | A rubric AI plan can be cut off by the model's hidden reasoning; the call is paid for and the student gets the phone's plan | Confirmed mechanism, frequency unknown | 4, 2 | Fixed in #52; needs a function deploy |
| A2 | The daily AI budget floor allows about five rubric markings a day across every paying, trial and tester account | Confirmed | 2, 1 | Owner decision |
| A3 | "Albus is at capacity" reaches the student as "couldn't finish marking that. Try again" | Confirmed | 2 | Small app fix, recommended before launch |
| A4 | Reminders say "1 assignments are still open" and "1 steps can't be placed" | Confirmed, seen in real output | 5 | App fix |
| A5 | Thirty reminder lines carry `**bold**` markers that the lock screen shows as asterisks | Plausible (to be confirmed on the simulator) | 5 | App fix |
| A6 | A purchase made while `REVENUECAT_APP_IDS` is unset is retried for a few hours only | Confirmed by reading | 2 | Order of the owner's steps |
| A7 | Deleting an account does not revoke Sign in with Apple until the Apple secrets are set | Confirmed by reading | 1, 3 | Owner step before submission |
| A8 | A fourth rubric on Free is refused by the server, and the app says only "Couldn't sync this rubric" | Confirmed | 5, 2 | Owner decision on wording |
| A9 | After a second account takes over a phone that held another's tasks, the app can show Free until the next refresh | Plausible | 3 | After launch |
| A10 | The privacy policy's sentence about Apple being unreachable has the gap Greptile found in the app | Confirmed | 5 | Website fix |
| A11 | Four tool tiles opened sites that have closed, and two opened addresses that do not answer | Confirmed in a browser | 1, 5 | Fixed in #51 |
| A12 | The first plan in onboarding waits for the AI answer with no upper limit short of the network timeout | Confirmed by reading | — | After launch |

Sign-in, purchase, restore and the first plan were read first. Nothing found in
them blocks the TestFlight build. The one fix from that pass, A1, is on the
server.

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
  logged as `RESPONSE_TRUNCATED`. It needs a deploy of `breakdown`.
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
- **Recommended fix.** Give it its own message that says marking is busy, that
  none of their markings was used (true: the refusal comes before anything is
  reserved), and to try later. Wording only, no behaviour change.

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

### A5. Reminder lines carry bold markers

- **Where.** Thirty lines in `Corpus.swift` and `Corpus+Deadline.swift`
  contain `**{step}**`; `ios/App/Albus/Services/NotificationScheduler.swift:179`
  copies the text into the notification unchanged.
- **What happens.** iOS shows notification text as plain text, so a reminder
  would read "History essay is due tomorrow. \*\*Outline the method\*\* is where
  you start."
- **Status.** Plausible until seen on the simulator.

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

## Decisions for the owner

To be completed at the end of the audit.

## After launch

To be completed at the end of the audit.
