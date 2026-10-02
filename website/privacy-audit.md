# Privacy copy audit — 22 September 2026

Reviewed against `payments/app` at 83a62b9 and the account-deletion implementation.
This is a code-to-copy audit, not certification of provider contracts or production settings.

| Claim | Evidence and correction |
| --- | --- |
| Original photos/files stay on the phone | `ios/App/Albus/Services/WorkExtractor.swift` uses Vision/PDFKit locally. `GradingService.Request` sends text, title, presentation instructions and rubric/assignment identifiers; no file bytes. Copy now includes the extra context. |
| Submitted text is never stored | **Incorrect.** `supabase/functions/grade/index.ts` persists `criteriaPayload.quote` inside `gradings.breakdown`; `_shared/grade_prompt.ts` caps each quote at 400 characters. Full input text is not a database field, but feedback can contain excerpts. Privacy and support now say this explicitly. |
| Raw device/IP values are never stored | `_shared/signals.ts` hashes IDFV and an IP prefix before `record_identity_link`. That establishes the app's anti-abuse-table behaviour, not provider logging. Copy now scopes the claim accordingly. Supabase's [Auth audit-log documentation](https://supabase.com/docs/guides/auth/audit-logs) includes IP addresses. |
| No analytics/tracking/push | No advertising or study-activity analytics SDK or remote-notification registration found in the app. `NotificationScheduler` uses local notifications. RevenueCat processes subscription activity, so the blanket analytics wording now distinguishes that purpose. |
| No name | Anonymous authentication requires no name; `Preferences` accepts an optional display name. Copy now distinguishes required and optional data. |
| AI provider stores nothing | No zero-retention agreement was verified. Anthropic's [commercial retention policy](https://privacy.claude.com/en/articles/7996866-how-long-do-you-store-my-organization-s-data), read on this date, states a standard 30-day API retention period with exceptions. Copy links to that policy rather than promising immediate provider erasure. Training is described as off by default under commercial terms, not an independently verified account configuration. |
| Deletion removes every record | Student content cascades; cost, purchase and security records survive with nullable ownership, while `identity_links` deliberately retains its pseudonymous observations. Copy now discloses these exceptions and local-cache removal. The existing retention rules are unchanged. |
| Anti-abuse retention is exactly 90 days | `prune-security-data` uses the last observation; scheduled cleanup removes expired records. Copy now says 90 days without another observation. |
| Marking returns later the same day | Limits can span rolling windows and monthly spending. Removed that promise. |
| Restore purchases restores work | Restore transfers subscription access, not the previous anonymous account's assignments. Support now makes that distinction. |

The approved public contact is **fgutort8@gmail.com**. No outbound message was sent.

## Update — 27 September 2026

Reviewed against `main` at 195f769, after the security fixes (#13, #20) and the
quiet CAPTCHA check (#22).

| Claim | Evidence and correction |
| --- | --- |
| Cloudflare runs a check at set-up | **Added.** `ios/App/Albus/Services/CaptchaService.swift` and `CaptchaPrefetch.swift` load `challenges.cloudflare.com/turnstile/v0/api.js` in a `WKWebView` with a non-persistent data store, during onboarding, when the build has a Turnstile site key. The pass goes to `signInAnonymously(captchaToken:)`, and Supabase verifies it with Cloudflare. Cloudflare's [Turnstile privacy notice](https://www.cloudflare.com/turnstile-privacy-policy/) (updated 18 June 2025) lists the signals (IP address, TLS fingerprint, User-Agent, site key and origin) and a second purpose, improving its bot detection. Copy names Cloudflare, both purposes, and that our server receives only the pass. |
| Accounts last until you delete them | **Incomplete.** `reap_abandoned_anonymous_users(30)` in `20260925140000_maintenance_account_guards.sql` deletes anonymous accounts with an untouched profile, no owned rows and no activity for 30 days. Copy now says a never-used account is removed automatically. |
| How much feedback can quote | **Corrected.** The 400-character cap in `_shared/grade_prompt.ts` applies only to each criterion's `quote`. Each criterion's `comment` keeps up to 1,200 characters, the overall `feedback` up to 4,000, and up to three priority changes up to 300 characters per field, and any of these can repeat or paraphrase the work. Copy no longer implies every excerpt is short or capped at 400. |
| The check runs once | **Incorrect.** `CaptchaPrefetch` fetches a new pass after 240 s unused, reloads a stalled page up to twice, and fetches another pass after a failed sign-up; the visible sheet can run one too. Copy now says it can run more than once during set-up. |
| Retention periods | Unchanged and confirmed: `prune_security_data(90, 180)` removes device/IP codes 90 days after the last observation and security records after 180 days; failed or reserved AI records go after 30 days; rate-limit windows after 2 hours (`20260925170000_subscription_ordering.sql`). |

## Publication gate

Account deletion (#9) and the payments backend and app (#2, #3) are merged and
live, so the earlier conditions are met. Publishing still needs the owner's go,
and the owner should confirm the provider settings that code cannot certify.

The Cloudflare paragraph describes builds made with a Turnstile site key. Publish
this policy **before** testers or students get such a build: disclosing the
check before it runs is safe, running it before it is disclosed is not.

## 1 October 2026: payments queue, terms of service

Reviewed against `main` after #30 (payment events saved before they are applied),
#29 (new API keys) and the queue follow-up (#31).

| Claim | Evidence |
| --- | --- |
| Payment events are queued with the account's id, then applied | `private.financial_inbox` in `20260930143051_financial_event_pipeline.sql` stores the allowlisted payload and `user_id`; `prune_financial_inbox()` (daily cron) erases payload and `user_id` 30 days after completion, keeping id, hash and result to refuse replays. Pending, retrying and dead events are never pruned (so a payment is not lost), and the policy says so. |
| Changes to plans and payments go to a log that can't be edited | `private.financial_audit`, appended by triggers on the five financial tables; update, delete and truncate are refused; accounts appear only as a SHA-256 hash. No automatic expiry, so it sits with "subscription records" under accounting retention. |
| An account with a payment still queued is never removed as unused | `reap_abandoned_anonymous_users` spares any account named in a `user_id` column; since `20261001190000` the enqueue also holds the account's row while recording. |
| Age | Terms and policy now say 13 or older, with a parent or guardian agreeing under 16 (stricter than Spain's 14). |
| Terms | New `/terms/`, Spanish law with EU consumers' mandatory protections kept; Apple's standard EULA still covers the app and is linked from the first paragraph. The app's Terms links (paywall, Settings) now open this page. |

## 2 October 2026: sign-in with Apple and email codes

Students now sign in before set-up (the owner's decision); see `SignInScreen.swift`
and `SessionService.swift`. Reviewed against this branch (`auth/app`); the server
half is `auth/server`.

| Claim | Evidence |
| --- | --- |
| We keep the email address (or Apple's relay address) only to sign in | Apple: `SignInScreen` requests the `email` scope only, never the full name; GoTrue stores the identity in `auth.identities`. Email: `sendEmailCode` sends the typed address to `/auth/v1/otp`. No other code reads `user.email` except Settings, which shows it to the student. |
| Cloudflare's check can run for email sign-in, never for Apple | The email code request goes through `AccountCreation` with the Turnstile pass; GoTrue's `isIgnoreCaptchaRoute` skips the check for `grant_type=id_token`. |
| A new phone gets the account and plan back, not the tasks | No task download exists; `LocalAccount` releases the server's active tasks when the phone holds none (`release_my_active_assignments`). |
| Signing out keeps the tasks; another account is asked before they go | `LocalAccount.decide` (tested in `LocalAccountTests`), `AccountSwitchScreen`. |
| Deleting an Apple account tells Apple | `AccountDeletionScreen` asks Apple for a fresh code; `delete-account` exchanges and revokes it (server half). |
| Sign-in codes expire after 10 minutes | `otp_expiry = 600` in `supabase/config.toml` (server half) and the dashboard setting. |
| Resend sends the codes | Owner's choice of provider in YOUR_STEPS; change the providers table if another is used. |
