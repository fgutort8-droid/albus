# Backend

Four Edge Functions carry the server product. The three student endpoints are
implemented and require a verified user JWT. RevenueCat is the only public
endpoint; it fails closed until its two webhook secrets and product allowlist
are configured.

| Endpoint | Auth | Job |
|---|---|---|
| `POST /breakdown` | user JWT | Assignment → rubric-grounded, startable steps, persisted atomically |
| `POST /grade` | user JWT | Work + the student's saved rubric → persisted grading; blind reading when there is none |
| `POST /revenuecat-webhook` | RevenueCat auth + body HMAC | Purchase events → server entitlement |

Almost everything else in the app runs on-device. Scheduling, re-planning,
tool matching, notifications, progress and per-user calibration need no
server — see the architecture notes for the full ledger.

---

## Model routing

Applying a rubric to a specific prompt is genuine reasoning and is the
differentiator, so it gets the stronger model. "Read chapter 12" is
decomposition, not reasoning, and is roughly two thirds of real volume.

| Case | Model | Safety-ledger rate /MTok |
|---|---|---|
| Breakdown with a saved rubric | `claude-sonnet-5` | $2 in / $10 out |
| Generic breakdown | `claude-haiku-4-5` | $1 in / $5 out |
| Grader with a rubric | `claude-opus-5` | $5 in / $25 out |
| Blind Grader reading | `claude-sonnet-5` | $2 in / $10 out |

These are the uncached rates configured in `private.ai_model_prices`, used to
derive cost from provider token counts. They are operational configuration and
must be updated when provider pricing changes. Routing lives in the pure prompt
modules and is unit-tested.

**Measured latency** (integration run, 2026-08-21): Sonnet with an 8-step
rubric plan ≈ **19s**; Haiku generic ≈ **3–5s**. Comfortably inside the
90-second first-plan target, but it is the dominant term — worth streaming
before adding anything else to that path.

## Prompt caching

`buildSystemPrompt()` is the cacheable half: identical for every student
taking the same assessment in the same course. `buildUserPrompt()` holds
everything volatile. A test asserts the system prompt contains no task title
and no dates, because a single volatile byte above the breakpoint destroys the
hit rate.

**Caching does not currently engage.** Anthropic will not cache a prefix below
roughly 1024 tokens, and the seeded three-criterion rubric produces ~900 input
tokens total. Expect `cache_read_tokens: 0` until rubric blocks grow. This is
correct behaviour, not a bug — but it means the per-call cost today is the
uncached figure.

## Structured output

`output_config.format` with a raw JSON Schema. No zod dependency.

The supported schema subset is narrower than full JSON Schema — verified by
the API rejecting these outright:

- `minItems` above 1 → rejected
- `minimum` / `maximum` on integers → rejected

So `BREAKDOWN_JSON_SCHEMA` encodes **shape only**, and every bound lives in
`validateAndNormalise()`. A schema can guarantee a field is an integer; it
cannot guarantee it is a sane number of minutes.

The validator clamps what is merely implausible and rejects only what cannot
be salvaged — a student waiting on a plan is better served by an adjusted plan
than an error. It also scales a plan down when the model's total overshoots
the student's stated budget by more than 50%.

## Plans and quota

Three tiers. Every limit lives in **`public.plans`** — one row per tier, read by
the gate, the meter and the paywall alike:

| | Free (€0) | Plus (€9.99/mo) | Pro (€17.99/mo) |
|---|---|---|---|
| Active tasks | 5 | 10 | unlimited |
| AI step plans | 5 / week | unlimited | unlimited |
| Albus Grader | — | 2 / week | 5 / week |
| Saved rubrics | 3 | 5 | unlimited |
| Tools | basic | expanded | all |

**`NULL` is unlimited. `0` is not included.** This is the load-bearing
convention in the whole feature and it *reverses* what migration 0031 did, where
`limit = 0` meant "no ceiling" because that was how Plus was expressed. With a
Free tier that genuinely gets zero gradings, the old reading would have handed
every free student unlimited use of the most expensive call the app makes.

The two are different refusals, different screens and different sentences:

| | code | HTTP | what the student is told |
|---|---|---|---|
| Not on this plan | `PLAN_UPGRADE_REQUIRED` | 402 | a price |
| Bought and used up | `ALLOWANCE_WEEKLY` / `ALLOWANCE_MONTHLY` | 402 | a date |
| Going too fast | `RATE_LIMIT_HOURLY` / `_DAILY` | 429 | "in a few minutes" |
| Account cost backstop | `FAIR_USE_REACHED` | 402 | capacity returns gradually over 30 days |

Collapsing the first two is how a paying student gets shown a paywall for
something they already bought.

**Rate limits are separate from allowances**, in their own columns. An allowance
is what the student bought; a rate limit is what stops a compromised or scripted
client burning it in four seconds. A Pro student has five gradings a week and
still cannot fire them all in one minute.

### Where a limit is enforced

Inside Postgres, in the same transaction as the write, under a per-user advisory
lock. Never in the Edge Function and never on the device.

| limit | enforced by |
|---|---|
| Breakdown, Grader | `check_and_record_ai_usage()` |
| Active tasks | `assignments_active_limit` trigger |
| Saved rubrics | `rubrics_limit` trigger |
| Steps per plan | `subtasks_limit` trigger |

The app has no raw INSERT/UPDATE grant on assignments, rubrics, courses or
subtasks. It writes through three narrow `SECURITY DEFINER` RPCs that derive the
owner from `auth.uid()`. Triggers independently enforce ownership and row-count
limits, so a future server path cannot bypass a rule by forgetting to call the
same helper. `assertCanGeneratePlan()` remains a cheap pre-flight so Albus does
not pay Anthropic for a generation the insert transaction will reject.

> **Two bypasses found by attacking the live database (migration 0036).**
>
> **The RPC was a suggestion.** A Free account already holding its five went to
> six by POSTing straight to `/rest/v1/assignments`, first attempt, no error.
> The cap had been bypassable since 0008 and was never noticed because the only
> client we ship happens to call the RPC.
>
> **Reserve-then-spend was racing.** Migration 0010 claimed two concurrent
> requests could not both read the last remaining unit. That is not true under
> READ COMMITTED: both read the same snapshot, both insert. A Plus account with
> one grading left, twelve simultaneous requests — **two** came back with a
> reservation. Fixed with `pg_advisory_xact_lock` keyed on the user.
>
> A note on how that was found: the same test run through one pooled connection
> reported a single winner and looked clean, because the tooling was serialising
> the requests it was supposed to be parallelising. A concurrency test that
> cannot demonstrate concurrency proves nothing.

> **Bug found and fixed earlier (migration 0009).** Only a purchase creates an
> `entitlements` row, so for free users the tier lookup returned NULL. In SQL
> `NULL = 'plus'` is NULL, not false, so `not (NULL and …)` was NULL and the
> `if` never fired — the cap was skipped for exactly the users it exists to
> limit. `coalesce(…, false)` is still load-bearing, and `effective_tier()` is
> now the one place that comparison is written.

## Trust boundary

`requireUser()` resolves identity from the verified JWT and ignores the body
entirely. A payload claiming `{"user_id": "..."}` is a claim, not a statement.

Functions get a caller-scoped Supabase client by default, so RLS applies
*inside* the function — a logic bug cannot read another user's rows. The admin
client is reached for explicitly, only for writes the user must not control
(`entitlements`, `ai_usage`).

The model only ever sees rubric **codes** (`A`, `B`), never criterion UUIDs.
Codes are mapped back to ids server-side against the rubric that was actually
loaded, so a hallucinated code becomes `null` rather than a foreign key into
another course's rubric.

## Testing

```bash
cd supabase/functions
deno task test     # pure logic, no network, no provider key
deno task check    # type-check every entrypoint
deno task lint
```

Integration test (real API call, costs a few cents, not in the default suite):

```bash
deno run --allow-net --allow-env _tests/integration_breakdown.ts
```

It exercises the rubric path, the generic path, a 20-hour task due tomorrow,
and a one-word title — and asserts the model never invents a criterion code.

Database-side behaviour is verified by `supabase test db --local` and
`scripts/security-concurrency-local.sh`. The first tests grants, RLS, quota,
risk, cost and subscription replay; the second opens real parallel Postgres
connections and races the final task, rubric and grading slots.


---

## Payments

Entitlement has exactly one source: the **RevenueCat webhook**. Nothing a
client sends can make anyone Plus or Pro.

```
RevenueCat  →  revenuecat-webhook  →  apply_subscription_state  →  entitlements
              (auth + body HMAC)      (allowlist/replay/expiry)     (server-written)
```

**`revenuecat-webhook`** is public — RevenueCat cannot present a user JWT — so
it requires both a constant-time checked Authorization secret and RevenueCat's
HMAC over the exact raw body. The signed delivery timestamp has a five-minute
window. Both secrets fail closed when absent, and oversized bodies are rejected
before parsing.

The database independently enforces the important facts:

- **Only configured Albus app ids are accepted.** A valid RevenueCat signature
  from another app in the same provider project still grants nothing.
- **Only allowlisted product ids grant a tier.** The mapping is server-only and
  currently empty, so an unconfigured payment system grants nothing.
- **Sandbox purchases grant nothing** in both the Edge Function and SQL unless
  an explicit test-project switch is enabled.
- **Event ids and times are persisted.** Replays and older events are ignored;
  a subscription already linked to one user cannot be claimed by another.
- **A missing expiry is inactive**, not lifetime access.
- **Cancellation is not revocation.** `CANCELLATION` means "will not renew";
  the student keeps what they paid for until `expires_at`.
- **A scheduled pause is not revocation.** `SUBSCRIPTION_PAUSED` keeps access
  through the paid period; the later `EXPIRATION` event revokes immediately.

### What still needs an account

The four products are mapped (`20260917130000_payments_backend`). The rest
lives outside the repo:

1. App Store Connect: create the four subscriptions with exactly the mapped
   product ids, in one group with Pro above Plus, and Billing Grace Period off.
2. RevenueCat: connect the app. The client logs in with the Supabase user id,
   lowercased. Leave restore behaviour on the default, **Transfer to new App
   User ID**: accounts are anonymous, so a new phone is a new account, and
   `transfer_subscriptions` moves the plan and its usage history.
3. RevenueCat → Integrations → Webhooks: point at
   `https://<project>.functions.supabase.co/revenuecat-webhook`; configure both
   `REVENUECAT_WEBHOOK_SECRET` (the Authorization header) and
   `REVENUECAT_WEBHOOK_SIGNING_SECRET`, and set the App Store app's RevenueCat
   id in `REVENUECAT_APP_IDS`. Until that is set the function answers 503 and
   RevenueCat retries.
4. Verify purchase, renewal, cancellation, expiry, refund, replay, restore and
   a sandbox purchase before release.

`app_config.allow_sandbox_subscriptions` is 1 because App Review and TestFlight
buy with sandbox accounts against this backend. Sandbox proceeds never raise
the paid fuse. Setting it to 0 stops sandbox purchases granting anything from
the next event on.

The superseded direct Apple receipt and notification functions were removed.
They must not be redeployed.

## Rate limiting and risk

`check_and_record_ai_usage` takes the global advisory lock and then a per-user
lock before reserving **ahead of the model call**. A failed result gives the
student's allowance back but remains an attempt and a conservative cost
reservation. That is what prevents deliberately malformed/rejected generations
from becoming an unlimited provider bill. Finalization is one-way and token cost
is derived from a server-owned model-price table.

An outer request gate (30/minute, 180/hour) runs immediately after JWT
verification, before body parsing and security telemetry. It also bounds callers
who repeatedly request a feature their plan does not include and therefore never
reach the AI reservation gate.

Burst limits come from `public.plans`, and are **halved at `elevated` risk and
quartered at `high`**:

| | free/hr | free/day | plus/hr | plus/day | pro/hr | pro/day |
|---|---|---|---|---|---|---|
| breakdown | 6 | 20 | 20 | 60 | 40 | 150 |
| chat | — | — | — | — | 12 | 40 |
| grade | — | — | 3 | — | 3 | — |

Separate budgets per kind, so exhausting chat does not block planning.

A second, private rolling-cost backstop bounds the maximum loss from one
compromised or farmed account. It uses measured server-priced token cost after
completion and keeps the conservative reservation for unfinished/unknown work.
The Anthropic client does not retry automatically: without provider-enforced
idempotency, retrying a timed-out request could turn one reserved call into
several billed generations. An explicit app retry receives a fresh reservation
and therefore re-enters every entitlement, rate, risk, and monetary check.
Launch ceilings are US$1 Free, US$3 Plus and US$6 Pro per rolling 30 days;
the client cannot read or write them. A restore moves the last 30 days of usage
with the subscription, so a fresh account does not bring fresh ceilings.

Above them sit two project-wide fuses, one for free accounts and one for paying
accounts, each allowing 100 calls/hour and counting finished calls at their
measured cost and unfinished ones at their reservation. Free is US$1/hour and
US$1/day. Paid starts at the same floor and its day grows to 25% of the last 30
days of production proceeds, divided by 30 (`private.ai_pool_budget`). An
emergency stop halts both.

### Account risk

`account_risk(uid)` returns a score, a band and the arithmetic behind both. Six
signals in four families — device sharing, network, behaviour, and account age.
It exists to catch "delete the app and sign up again" farming, and it is
designed around one constraint above all others: **a device is not a person and
an IP is not a household.** A school hands out shared iPads; a carrier puts a
city behind one address.

Three rules the code enforces, not merely intends:

1. **No single signal escalates past `elevated`.** Two independent families are
   required. Account age is excluded from that count — every real student is
   minutes old exactly once.
2. **A paid account is never escalated past `elevated`.** A completed payment is
   the strongest identity check in this system.
3. **Escalation buys friction, not a door.** `elevated` halves burst limits;
   `high` quarters them and asks for a real sign-in (only once there is one to
   ask for — see `risk_verification_available`); only `severe` refuses, and only
   model calls. Every screen and everything already written stays reachable at
   every band, and every band recovers on its own as the signals age out.

Verified against the live database: 30 fresh accounts on one school network
score 40 / `elevated` / one family — tightened, never blocked. Six accounts from
one device in one afternoon score 90 / `severe` / two families — refused, and
back to `elevated` twenty-five hours later without anyone intervening.

**Only hashes are stored.** The Edge Function computes
HMAC-SHA256(value, pepper) and sends the digest; no IP address and no device
identifier ever reaches Postgres. The IP is reduced to a /24 (or /48) prefix
first — less identifying, and the right granularity for the question. The device
identifier is iOS `identifierForVendor`: per-vendor, resets on delete, not a
hardware serial, and the client may withhold it with no consequence.

`x-forwarded-for` is read from the **last** entry, not the first. The first is
the conventional "original client" and is exactly the one a client can forge; a
signal an attacker picks is worse than no signal, because it looks like evidence.

`security_events` records refusals — the code and the endpoint, never a request
body. It is written from the Edge Function rather than the gate on purpose: a
raised exception rolls back its own transaction, so a log line written next to
the `raise` would be discarded along with it.

## Advisor findings that are intentional

The database advisor reports three classes of finding on this schema. All are
expected; none is an oversight.

- **`rls_enabled_no_policy`** on `subscription_transactions`, `app_config`,
  `identity_links` and `security_events` — deliberate. RLS on, no grants, no
  policies means every client role is denied outright. This is the strongest
  posture available, and the linter reads the absence of policies as an
  omission. For the two risk tables it is also the point: a student who could
  read `identity_links` would be able to enumerate which classmates share their
  school's network hash.
- **`authenticated_security_definer_function_executable`** on `my_plan`,
  `my_tier`, and the three controlled write RPCs. These are the narrow client
  API above tables whose raw grants are closed. They derive the owner only from
  `auth.uid()`, schema-qualify their relations, and take no user-id parameter.
  AI reservation/finalization and every internal function that *does* take a
  uid are service-only; the obsolete client-callable forms were dropped.
- **`auth_allow_anonymous_sign_ins`** — the entire product is anonymous-first.
  Every user holds the `authenticated` role via an anonymous session; this is
  the design, not a leak. `public.plans` appears here because it is readable by
  every signed-in user, which is intended: it is a price list.
- **`auth_leaked_password_protection`, `auth_insufficient_mfa_options`** — the
  app has no passwords and sends no email. Both become relevant only when Apple
  Sign-In is switched on.
