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

## Publication gate

Do not publish yet. Deletion must be merged, and the owner must deploy its RPC.
The pages also describe the unmerged payments backend/app (PRs #2 and #3).
This work does not authorize merging those unrelated changes or deploying production.
The owner must verify actual provider contractual settings and purchase readiness
before publication; code alone cannot certify those claims.
