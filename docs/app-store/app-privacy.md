# App Privacy answers

Audit date: 22 September 2026. Source baseline: `ac63956`; see `verification.md`
for the built revision and dependency inventory. These are proposed App Store
Connect answers, not a statement that production settings were inspected.

The app creates an anonymous account, but Apple still considers data associated
with its account UUID or device identifier **linked to the user**. Hashing the
IDFV or removing ownership after deletion does not make collection unlinked.
No inspected path combines data with other companies' data for advertising or
sends it to a data broker: **tracking is No throughout**.

The manifest covers the app's collection. App Store Connect must also include
partners' collection. Sources: [Apple's privacy labels](https://developer.apple.com/app-store/app-privacy-details/),
[manifest data types](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacycollecteddatatypes/nsprivacycollecteddatatype),
and [RevenueCat's disclosure guidance](https://www.revenuecat.com/docs/platform-resources/apple-platform-resources/apple-app-privacy).

## Answers for every Apple data type

For a No row, purpose and linkage are not applicable; tracking remains No.
For every Yes row below, select **App Functionality**, **Linked: Yes**, **Tracking: No**.
This includes authentication, delivering requested features, account limits,
security and subscription access. Do not select advertising/marketing purposes.

| Apple data type | Collected? | Evidence / scope |
| --- | --- | --- |
| Name | No | `OnboardingFlow.swift` stores the optional display name in `Preferences.swift` on the device. `ProfileService.swift` sends subject names, not the student's name. A `profiles.display_name` column alone is not evidence of collection by this client. |
| Email Address | No | `SessionService.swift` uses anonymous auth; no email field or email login. External support email is addressed separately below. |
| Phone Number | No | No phone field, telephony read or phone-auth flow in app sources. |
| Physical Address | No | No address collection or shipping flow. |
| Other User Contact Info | No | No social handle/contact field sent by the client. |
| Health | No | No HealthKit/medical-data feature. Incidental text inside a student's assignment is handled as Other User Content, not structured health collection. |
| Fitness | No | Study timers measure studying, not exercise; no motion/fitness collection. |
| Payment Info | No | No card/bank fields. Apple handles payment credentials; subscription transaction identifiers are Purchase History. |
| Credit Info | No | No credit scoring or credit fields. |
| Other Financial Info | No | No student income, assets or debt. Developer AI costs and subscription receipts are not the student's financial profile. |
| Precise Location | No | No CoreLocation or coordinates. |
| Coarse Location | No in app code | `signals.ts` groups IP prefixes for abuse prevention; it does not geolocate. Verify provider settings before submission: if a partner derives/stores location, change this answer. |
| Sensitive Info | No | No dedicated sensitive-attribute collection, biometric identification or inference. Free-form work is Other User Content. |
| Contacts | No | No Contacts framework or contact-picker access. |
| Emails or Text Messages | No | No access to inbox/SMS or messaging feature. Pasted assignment prose is Other User Content. |
| Photos or Videos | No | `WorkExtractor.swift` converts selected images/PDFs locally; `GradingService.Request` transmits text, not image/video bytes. |
| Audio Data | No | No recording or audio upload path. |
| Gameplay Content | No | No game or gameplay uploads. |
| Customer Support | No in-app collection | No in-app support form/upload. The policy's mailto opens an external mail client; support handling needs owner confirmation below. |
| Other User Content | Yes | `PlanService.swift`, `ProfileService.swift`, `RubricService.swift`, `GradingService.swift`: assignment/subject names, deadlines, rubrics, submitted text, presentation instructions and work titles. `grade/index.ts` persists feedback and quotes; `grade_prompt.ts` caps each quote at 400 characters. Full text also reaches Anthropic, whose retention is not assumed to be zero. |
| Browsing History | No | `ToolsScreen.swift` opens fixed tool URLs externally with `openURL`. It does not receive Safari browsing history. |
| Search History | No | Tool filtering is local `@State query` in `ToolsScreen.swift`; no search endpoint or query logging. |
| User ID | Yes | `SessionService.swift`, `_shared/auth.ts`, ownership columns and request JWTs. Anonymous UUIDs remain account identifiers. |
| Device ID | Yes | `DeviceSignal.swift` sends IDFV; `_shared/signals.ts` stores a keyed hash associated with an account. No IDFA collection. |
| Purchase History | Yes, backend path | `revenuecat-webhook/index.ts` and `0010_ratelimit_and_subscriptions.sql` accept/store product and transaction state linked to the account. In-app buying is blocked on payments/app; retaining this disclosure covers the existing backend and intended release. |
| Product Interaction | Yes | `_shared/quota.ts` / `ai_usage` retain requested AI feature, attempt/completion state and usage counts to enforce allowances and control service cost. This is not an advertising event stream. |
| Advertising Data | No | No ads or advertising SDK/event path. |
| Other Usage Data | No additional category | The known off-device feature-use records are Product Interaction. `CompletionRecord` and `NotificationState` are local; no completion-upload consumer was found. Do not infer collection from an unused server table or a stale sync comment. |
| Crash Data | No app collector | No crash-reporting SDK/uploader found. Apple's platform collection is separate from developer-added collection. Recheck when adding any diagnostics SDK. |
| Performance Data | No app collector | No launch/freeze/energy or request-latency uploader in app code. Provider log configuration remains an explicit release check below. |
| Other Diagnostic Data | Yes | `_shared/http.ts`, `_shared/signals.ts`, `_shared/quota.ts` record errors, refusal kinds and failed requests; some records carry account identifiers. |
| Environment Scanning | No | No ARKit scene/depth collection. Document OCR is not environment reconstruction. |
| Hands | No | No hand tracking. |
| Head | No | No head tracking. |
| Other Data | Yes | `_shared/signals.ts` retains keyed network-prefix observations for abuse prevention. Treat these as linked security data, not location or anonymous aggregate statistics. |

File references above are under `ios/App/Albus/{Services,Screens,Models}` or
`supabase/{functions,migrations}` as named. The table deliberately uses code
consumers, not table existence, as evidence.

## Policy reconciliation and release decisions

Starting point: `origin/codex/privacy-support:website/privacy-audit.md` and
`website/privacy/index.html` at `31bee61` (PR #6). That branch is read-only for
this task; none of its files were changed here.

- Agreement: original files stay on-device, while extracted marking text goes
  to Anthropic; saved feedback may contain excerpts. Other User Content is Yes.
- Agreement: no required contact details, ads, cross-app tracking or remote push
  service. Optional local name/preferences are not off-device collection.
- Agreement: deletion does not erase all financial/security evidence. Linked
  collection must still be disclosed even if ownership is nulled later.
- Clarification: no third-party study-activity analytics SDK does **not** mean no
  Product Interaction data. AI request accounting is described by the policy and
  is disclosed here as functionality, not marketing analytics.
- **Policy gap:** `CaptchaService.swift` can load Cloudflare Turnstile when a
  release site key is configured. PR #6 does not name Cloudflare. Its placeholder
  configuration disables the widget; the owner's real release settings were not
  inspected. Before enabling it, name the provider and verify its data handling
  against [Cloudflare's Turnstile privacy addendum](https://www.cloudflare.com/turnstile-privacy-policy/).
  The addendum identifies IP address, TLS fingerprint, user agent and origin/site key as signals. Confirm the release integration and retention rather than assuming the widget is data-free.
- **Partner verification needed:** Supabase's auth/hosting logs may contain raw
  IP/request metadata beyond the app's hashed tables. The policy acknowledges
  provider logs, but their production configuration/retention was not inspected.
  Confirm whether provider performance or geolocation collection changes the No
  rows above before submitting. No production access was used for this audit.
- **Support decision:** external emails to fgutort8@gmail.com can contain a name,
  email address and support content. There is no in-app support collection in
  this build. The owner must confirm whether the operational support channel
  qualifies for Apple's optional disclosure; if it does not, disclose Email
  Address, Customer Support and Name when collected, linked, for functionality.
- **Payments gap:** RevenueCat is absent from the audited target and the purchase
  button is a stub. PR #6 describes working purchases/restore; that promise is
  ahead of this build. After payments/app lands, inspect its bundled manifest,
  actual configured integrations and user-ID linkage. RevenueCat's manifest
  alone does not answer the developer's App Store Connect questionnaire.

These are release gates, not permission to invent reassuring answers. The owner
must reconcile actual partner settings before using this document as final ASC input.
