# Albus security and financial-safety model

This document describes the current system, not the intended one. The threat
model is simple: **the iOS client is hostile**. A student can inspect it, patch
it, replace every local entitlement value, replay requests, call Supabase
directly, and send arbitrary ids and documents. Nothing on the device decides
whether another person's data is visible or whether Albus pays for an AI call.

## 1. Identity

Every student is a real `auth.users` row. First launch creates an anonymous
Supabase user and stores its rotating session in the iOS Keychain. Anonymous
users hold the `authenticated` Postgres role; `anon` means no signed-in user and
has no table grants at all.

The Keychain survives ordinary app deletion, so reinstalling does not normally
mint a fresh allowance. It is not treated as proof of personhood: accounts can
still be created outside the app, which is why rate, risk, and global financial
controls exist underneath it.

`requireUser()` validates the bearer token with Supabase Auth. Identity always
comes from that JWT's `sub`; no Edge Function accepts `user_id` from a body.

## 2. Data isolation and the write surface

Every `public` table has RLS enabled. User-owned SELECT/DELETE operations compare
`(select auth.uid())` with the row owner, and restrictive owner policies remain
an invariant underneath permissive policies. Reference data is read-only.

Raw access is narrower than the policies:

- `entitlements`, `ai_usage`, subscription, risk, and security-event tables have
  no client grants in either direction.
- assignments are readable and owner-deletable; creation goes through
  `create_assignment_with_plan`.
- rubrics are readable and owner-deletable; writes go through `upsert_rubric`.
- courses are readable; creation goes through `create_course`.
- remote subtasks are read-only. Remote plan sessions and completion logs are
  outside the client surface because the current app schedules and estimates in
  SwiftData, not those tables.

The three write RPCs derive the owner from `auth.uid()` and run elevated only so
their base-table grants can stay closed. Their bodies schema-qualify every
relation. Triggers independently enforce course/rubric ownership, active-task
limits, rubric limits, child limits, and high absolute abuse ceilings. Thus a
future caller cannot bypass a rule by skipping the RPC.

`my_plan()` and `my_tier()` take no user argument. Internal functions which do
take a user id are revoked from `authenticated`, preventing one-row-at-a-time
subscription or usage enumeration.

## 3. Keys and Edge Functions

| Secret | Location | Property |
|---|---|---|
| Supabase publishable key | iOS app | public by design; RLS applies |
| Supabase secret key | Edge Functions, injected by the platform | bypasses RLS; never in client/repo |
| `ANTHROPIC_API_KEY` | Edge secrets | pays for model calls |
| RevenueCat webhook secrets | Edge secrets | authenticate and sign payment events |
| `ALBUS_SIGNAL_PEPPER` | Edge secrets | makes stored signal hashes non-reversible |
| `APPLE_TEAM_ID` | Edge secrets, set by the owner | lets the server revoke Sign in with Apple |
| `APPLE_KEY_ID` | Edge secrets, set by the owner | lets the server revoke Sign in with Apple |
| `APPLE_PRIVATE_KEY` | Edge secrets, set by the owner | lets the server revoke Sign in with Apple |
| `APPLE_CLIENT_ID` | Edge secrets, set by the owner | lets the server revoke Sign in with Apple |

Functions take their Supabase keys from `resolveKey` in `_shared/auth.ts`: a
hand-set `ALBUS_SUPABASE_*_KEY` override first, then the platform's
`SUPABASE_SECRET_KEYS` / `SUPABASE_PUBLISHABLE_KEYS` (entry `default`), then the
single key a local stack injects, and the legacy `service_role` / `anon` JWT
keys last. The legacy keys stop working at the end of 2026; once the functions
run this order in production they can be deactivated in the dashboard.

Each function logs `supabase keys` with the source of both keys as it starts,
by name only (`override`, `platform`, `local`, `legacy`), never a key value.
Before deactivating the legacy keys, call each deployed function once and check
that its log says `platform` for both: an `ALBUS_SUPABASE_*_KEY` override, or
dashboard keys not named `default`, would leave it on a legacy key. Supabase
lets deactivated legacy keys be re-activated. Do that first if a function ever
has to be rolled back to a version from before this order: those versions read
only the override or the legacy keys, and fail to authenticate without them.

Student functions have gateway JWT verification enabled and call `requireUser`
again. The RevenueCat webhook is the sole no-JWT function because RevenueCat is
not an Albus user; it has two independent checks described below.

Bodies are streamed through byte ceilings before JSON parsing: 16 KiB for plan
generation, 128 KiB for grading, 64 KiB for RevenueCat, and 2 KiB for account deletion.
Field-level limits then bound prompt content. A declared or streamed oversized
body is cancelled before full allocation.

User-owned ids are loaded through the caller-scoped client, so RLS decides what
they resolve to. Breakdown additionally rejects a foreign course/rubric before
calling Anthropic, avoiding a paid generation that is guaranteed to fail when
saved. Prompt inputs are fenced and tag-like student text is stripped; output
is schema-constrained and normalized before persistence.

`delete-account` authenticates the caller and loads their Apple identity through
the admin client. It exchanges a fresh authorization code, compares the Apple
subject, revokes the refresh token (or access token), then calls the existing
caller-scoped `delete_my_account()` RPC. A missing code, expired code, or another
Apple ID stops deletion. Missing Apple secrets and upstream failures never block
account erasure: an awaited warning is recorded before the user is deleted,
without codes, tokens, subjects, emails, or device/network hashes. The response
reports whether Apple revocation succeeded. There is no request-rate gate:
the existing gate accepts only AI endpoints, each attempt makes at most one
exchange and revoke, and a successful deletion removes its authenticated caller.
`scripts/security/delete-account-boundary.py` runs in the Database security
workflow against the real local function: a student's own token deletes exactly
that account, and a missing, forged or spent token deletes nothing.

## 4. AI financial protection

The order is intentional:

1. verify JWT;
2. enforce a compact per-account API request window (30/minute, 180/hour);
3. parse and validate bounded input;
4. load only caller-owned context;
5. acquire the global then per-user database locks;
6. check the emergency stop, read the plan, and check the call count and USD
   budgets of that plan's pool (free or paid);
7. evaluate account risk;
8. check the plan's delivered-result allowance and all-attempt rate limits;
9. reserve a worst-case cost row;
10. call Anthropic;
11. finalize the reservation once with server-derived token cost.

The app cannot execute reservation or finalization RPCs. The Edge Function uses
the service role and passes the id obtained from the verified JWT.

Automatic provider retries are disabled. The Messages API does not provide a
dependable idempotency guarantee for SDK retries, so one database reservation
maps to at most one Anthropic request. A user-initiated retry is a new attempt
and must pass every gate above again.

Allowance and financial exposure are deliberately different counters:

- completed work and genuinely in-flight reservations consume the student's
  purchased allowance;
- failed work gives the allowance back;
- every attempt, including failures, consumes the rate window;
- every reservation, including an abandoned one, consumes cost capacity in
  its pool for its hour/day: its measured cost once finished, its worst case
  until then.

This prevents both failure farming and a runtime crash erasing cost evidence.
Finalization is a one-way `reserved -> completed|failed` transition; replaying
it cannot alter outcome, model, owner, or cost.

Launch circuit breakers live in server-only `app_config`, one set per pool, so
accounts that cost nothing to create cannot use up what paying students need.
Each pool allows 100 AI calls/hour. Free accounts share US$1/hour and US$1/day.
Paying accounts start at the same floor, and their day grows to 25% of the last
30 days of production proceeds divided by 30, with a quarter of the day
available in any hour (`private.ai_pool_budget`). An emergency stop halts both
at once. The floors are intentionally low until real traffic establishes safe
capacity.

Each account also has a private rolling 30-day loss ceiling: US$1 Free,
US$3 Plus and US$6 Pro. Completed calls count measured server-priced tokens;
unfinished or unknown calls retain their worst-case reservation. A crashed Edge
isolate therefore cannot erase cost, and one manipulated account cannot consume
an unbounded share of the project budget. This backstop is separate from, and
checked after, product entitlement so its refusal is never presented as a plan.

Current paid allowances are server rows, not UI literals: Free gets no grading;
Plus gets two gradings per rolling seven days; Pro gets five. "Unlimited tasks"
has a 500-active/2,000-total abuse ceiling that no honest student should
encounter.

## 5. Account farming and privacy

The risk model combines account age, behavior, repeated account creation,
privacy-preserving device correlation, and a coarse network prefix. A device or
IP is never treated as a person:

- no single signal can escalate beyond `elevated`;
- `high`/`severe` requires at least two independent signal families;
- paid accounts are capped at `elevated` because payment is the strongest
  verification available;
- bands age away automatically; existing data never becomes inaccessible.

The app optionally sends iOS `identifierForVendor`, not an advertising id or
hardware fingerprint. The Edge Function reduces IPs to IPv4 `/24` or IPv6
`/48`, HMACs both values with the secret pepper, then discards the originals.
Postgres receives only 64-character digests.

Hostile telemetry is bounded: at most eight device and sixteen network hashes
per user, and at most fifty security events per user/hour. Security events carry
an endpoint and machine code, never a prompt, essay, message, raw IP, or raw
device id. Deleting an anonymous account does not erase its device/network
observations: the now-pseudonymous account UUID remains for the 90-day fraud
window, while the auth row and all student content delete normally. The daily
retention job then removes the observation.

Anonymous signup is limited to ten per IP/hour. CAPTCHA/Turnstile remains a
launch blocker because server-side CAPTCHA cannot be enabled until real
Cloudflare keys are configured on both client and Supabase.

## 6. RevenueCat and entitlements

The client never writes entitlement state. RevenueCat calls a public webhook
which requires:

1. a constant-time checked Authorization secret; and
2. RevenueCat's HMAC over `timestamp.raw_body`, with a five-minute delivery
   replay window.

The signed event id and event time are persisted. Replays and out-of-order
events are ignored. A subscription belongs to the first account an event names
until a signed `TRANSFER` moves it; an event naming a different account is kept
as a fact for the current owner and grants the other account nothing. Products
grant nothing until explicitly mapped in the server-only
`subscription_products` allowlist. A second allowlist, `REVENUECAT_APP_IDS`, is
required and restricts signed events to Albus's RevenueCat app ids, because one
RevenueCat project can deliver events for several apps. Only App Store events
can grant; RevenueCat Test Store purchases are acknowledged and ignored.
Unknown apps/products and null expiry fail closed.

Sandbox purchases grant while `app_config.allow_sandbox_subscriptions` is 1,
because App Review and TestFlight buy with sandbox accounts against the
production backend. The switch exists only in the database. Sandbox money never
raises the paid fuse, each sandbox account keeps its 30-day ceiling, and
Apple's sandbox subscriptions lapse within hours.

Cancellation keeps access until paid expiry. A `SUBSCRIPTION_PAUSED` event also
keeps access until paid expiry because it schedules a pause; only the later
`EXPIRATION` event revokes immediately. `PRODUCT_CHANGE` is informational and
does not change entitlement before the provider reports the actual transaction
state.

Accounts are anonymous, so a new phone is a new account, and Restore has to be
able to move an active subscription. RevenueCat's restore behaviour therefore
stays on **Transfer to new App User ID**; "only if there are no active
subscriptions" would refuse exactly the restore a student with a new phone
needs. A signed `TRANSFER` runs `transfer_subscriptions`: the transactions
move, both accounts are recomputed, and the last 30 days of AI usage move with
the plan. Every per-account AI limit counts that history, so walking one
subscription through fresh accounts does not multiply the weekly markings, the
rate limits or the 30-day ceiling. The transfer takes the AI gate's locks in
the gate's order; `scripts/security-concurrency-local.sh` races restores,
renewals and AI calls on the same accounts and fails on any deadlock.

Purchase, renewal and refund events record their proceeds in the server-only
`subscription_revenue` ledger: RevenueCat's price less its tax and commission
estimates (25% and 30% when missing), with the gross capped at US$1,000 so a
malformed event cannot open the fuse. Refunds count against.

Verified events are saved before they change anything. The webhook writes the
event's allowlisted arguments, never the raw body, to `private.financial_inbox`,
keyed by the signed event id, then processes it in a separate transaction that
applies the subscription change, records revenue, writes audit rows and marks
the event done, all or nothing. A duplicate or concurrent delivery gets the
first result instead of a second effect, and an event id reused with different
contents is refused. If processing fails, nothing it did survives, the event
stays queued, the webhook answers 503, and `albus-financial-drain` retries it
every five minutes with backoff. A product with no plan mapping is the one
exception: the money it moved is recorded at once, as it always was, and only
the plan change waits in the queue. After ten failures an event becomes a dead
letter that only the database owner can requeue, with a ticket reference. A
queued or dead event names its account in a `user_id` column, so account
cleanup keeps that account. See
[the payment event runbook](security/financial-security-runbook.md).

App Store products, the webhook secrets and `REVENUECAT_APP_IDS` are not
configured yet, so the webhook answers 503 and nothing can be bought. The
removed direct Apple receipt endpoints must not be redeployed.

## 7. Retention and operations

`prune-security-data` runs daily. It removes expired rate buckets after two
hours, failed/abandoned AI attempts after 30 days, identity links after at least
90 days, and security events after at least 180 days. Successful AI rows remain
for cost reconciliation but contain counts and model names, not submitted work.
The Grader stores result/feedback and a content hash; it never stores the essay.

`albus-financial-payload-retention` runs daily: after 30 days a completed
payment event keeps only its id, hash and result, which is enough to refuse a
replay. Every change to entitlements, subscription transactions, revenue,
products and `app_config` is written to `private.financial_audit`, which refuses
updates, deletes and truncation and names accounts only by a SHA-256 hash.

Production operators must keep Supabase/GitHub MFA enabled, rotate any exposed
provider key, review security events and circuit-breaker usage, and test a kill
switch before launch. Logs must never include request bodies or secrets.

### Deleting an account

`delete_my_account()` derives the account from `auth.uid()` and deletes its
`auth.users` row. The following inventory was checked on the disposable local
stack rebuilt from every migration (CLI 2.98.2, PostgreSQL 17). Its catalog has
31 application tables, 38 foreign keys reaching `auth.users`, 15 account-like
columns without a foreign key, and zero Storage buckets. The exact catalog
queries and output are included in the PR description. This is local evidence;
production still needs the owner's deployment review.

| Database location | What deletion does |
|---|---|
| `public.profiles`, `courses`, `assignments`, `subtasks`, `plan_sessions`, `completion_logs`, `rubrics`, `rubric_items`, `gradings`, `entitlements` | Deleted by owner/parent cascades, including grading feedback and its content hash. |
| `private.api_rate_windows` | Deleted by owner cascade. |
| `public.ai_usage` | Kept for cost reconciliation; `user_id` becomes null. Failed/reserved rows expire after 30 days; completed rows have no scheduled expiry. |
| `public.security_events` | Kept without `user_id`; scheduled deletion after 180 days. No student content is allowed. |
| `public.identity_links` | Kept deliberately with the pseudonymous account UUID and keyed device/network hashes; deleted after 90 days without another observation. This UUID is retained, not replaced with a hash. |
| `public.subscription_transactions` | Kept for accounting and restore routing. `user_id` becomes null, but `ownership_origin_user_id` and `ownership_path` still retain account UUIDs. |
| `public.subscription_revenue` | Kept for accounting; `user_id` becomes null. Purchase and event identifiers remain. |
| `public.subscription_webhook_events` | Kept replay evidence, indexed by provider event ID; no account column. |
| `private.subscription_transfers` | Kept restore routing. `active_destination_id` becomes null, but `source_ids` and `destination_id` retain account UUIDs. |
| `private.ai_usage_purchases` | Kept links between retained usage and purchases. Links expire after 30 days of usage age; parent deletion also cascades. |
| `private.financial_inbox` | Kept payment-processing evidence. No owner FK: `user_id` and the allowlisted JSON payload still name a deleted account. Completed payloads and `user_id` are cleared after 30 days; pending/retry/dead events retain their details until processing succeeds. |
| `private.financial_audit` | Kept immutable evidence with only a SHA-256 account/resource hash and allowlisted financial fields, never student content or the raw UUID. No scheduled expiry. |
| `public.curricula`, `course_templates`, `assessment_types`, `rubric_criteria`, `duration_priors`, `plans`, `app_config`, `subscription_products`; `private.ai_model_prices`, `ai_tier_budgets` | Kept shared reference/configuration data; no student ownership. |
| `auth.users`, `auth.identities`, `auth.sessions`, `auth.one_time_tokens`, `auth.mfa_factors` | Deleted, as are session/factor children and user-owned OAuth/WebAuthn records. |
| `auth.refresh_tokens` | Deleted through `session_id → auth.sessions`; its text `user_id` has no owner FK. A legacy orphan with no session cannot be proven erased by this SQL RPC. |
| `auth.flow_state` | No FK on `user_id` or `linking_target_id`; the SQL deletion RPC does not clear OAuth/PKCE flow state. The current app uses native ID-token sign-in, but older flows need separate verification. |
| Storage | No buckets in the rebuilt stack and no app upload path. Storage owner fields have no owner FK; future uploads would require explicit erasure. |

`prune-security-data` runs `prune_security_data(90, 180)` daily at 04:43
(database schedule), and `albus-financial-payload-retention` runs
`prune_financial_inbox()` daily at 03:23. The former also clears expired rate
windows after two hours, failed/reserved AI attempts after 30 days, and purchase
usage links after 30 days. These jobs do not scrub the permanent restore-route
UUID fields above.

| Outside our database | What happens |
|---|---|
| RevenueCat | Uses the Supabase account UUID. Albus currently makes no RevenueCat customer-deletion request. Open item: define and implement that provider deletion, including paid-account handling. |
| Email | No email provider is used and Albus sends no sign-in email; native Sign in with Apple is the only new-account path. Apple may supply a contact/relay address, erased with the auth account locally. |
| Anthropic | Receives the requested planning/marking text. Account deletion does not call an Anthropic erasure endpoint. Provider retention is governed by its [commercial data-retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data), not by our database cascades. |
| Apple | The `delete-account` function exchanges a fresh code, compares the identity and revokes Apple's token before local deletion. Upstream outages or missing secrets allow deletion with `apple_revoked: false`; the student can remove Albus in Apple's settings. Deletion does not cancel an App Store subscription. |
| Supabase backups and operational logs; copies on other phones | Outside this SQL transaction. No cross-device task wipe or provider-log erasure is implemented. |

**Audit result and the privacy policy.** Student-content erasure, security
retention, completed and queued payment retention, and Anthropic retention match
the privacy policy. The policy used to say financial records "no longer link to
your account", which the retained UUIDs above contradict. Since 7 October 2026
(PR #34) its deletion paragraph says that subscription records and queued
payment events keep the account's random identifier, as does RevenueCat's
customer record, and that Apple revocation is best effort. Still open, as
billing changes of their own: asking RevenueCat to delete the customer when the
account is deleted, and replacing the retained restore-route UUIDs with a hash.
The erasure test labels the retained UUID cases `RETAINED, disclosed` so a
passing run can't be mistaken for proof of complete financial unlinking.

## 8. Verification

After any schema or entitlement change:

```bash
supabase start
supabase db reset --local --no-seed --yes
supabase db lint --local --level warning
supabase test db --local
scripts/security-concurrency-local.sh
```

The pgTAP suite performs 535 privilege, RLS, plan, rate, risk, cost, replay,
assignment-status and account-erasure assertions across 13 files, each in a
rolled-back transaction. The erasure assertions explicitly expose retained
financial UUIDs; see the audit result in §7. The shell test opens twelve
real Postgres connections for one remaining grading/task/rubric and requires
exactly one winner in each race. It also races phones reopening tasks against
new tasks for the last place (one winner in 24), and Stop counting against a
phone that still holds every task (no freed task comes back). A one-connection
test cannot prove locking.

Also run Edge unit tests, Swift core tests, and iOS unit tests. CI runs database
containers only when migrations/security tests change to keep GitHub cost low.

## 9. Explicit blockers before production

- Rotate the previously exposed Anthropic key and set the dedicated signal
  pepper.
- Configure Turnstile and enable CAPTCHA in client and Supabase together.
- Enable Apple Sign-In/account linking before taking payment.
- Configure RevenueCat products, SDK, dual webhook secrets, and product map;
  verify purchase, renewal, cancellation, expiry, refund, replay, and conflict
  in Sandbox before enabling Production products.
- Enable MFA on Supabase, GitHub, Apple, Anthropic, and RevenueCat accounts.
- ~~Remove temporary Pro grants and old deployed Apple Edge Functions.~~ Done:
  on 29 Sep 2026 every entitlement row was Free and only `breakdown`, `grade`
  and `revenuecat-webhook` were deployed, byte-identical to `main`.
- Apply migrations/functions to production and test the AI emergency stop and
  budget alerts. The live advisor audit ran on 29 Sep 2026: no table without
  RLS, no client grant on server-only tables, no function callable by `anon`,
  and the six client RPCs each pinned to an empty `search_path` and scoped to
  `auth.uid()`.
- Deploy the functions that read the new Supabase keys, check their
  `supabase keys` log lines say `platform`, then deactivate the legacy
  `anon` / `service_role` keys before they stop working at the end of 2026.
