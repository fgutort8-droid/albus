# App Privacy answers

Written 16 November 2026, checked against `main` at `1509386` with the open
pull requests merged on top, and against the privacy policy dated 4 November
(`website/privacy/index.html`). Production settings were not inspected.

App Store Connect asks these in order. Each answer below says what to tick.

## 1. Data collection

**Do you or your third-party partners collect data from this app?** Yes.

## 2. Data types to tick

Tick exactly these eight. They are the eight in the app's privacy manifest
(`ios/App/Albus/PrivacyInfo.xcprivacy`), which `scripts/verify-app-privacy.py`
checks against the built app.

| Section in App Store Connect | Tick | What it is in Albus |
| --- | --- | --- |
| Contact Info | **Email Address** | The address Sign in with Apple shares, which can be a private relay address. Kept with the account, used only to find the account when the student writes to support. Albus sends no email. |
| User Content | **Other User Content** | Task details, subjects, saved rubrics, notes, marking results with their quotes (up to 400 characters each), work titles, the text sent to Anthropic for a plan or a marking, and which of a rubric's criteria the student chose to be marked on. |
| Identifiers | **User ID** | The account's random identifier, and the identifier Apple makes for Albus. RevenueCat is given the account identifier too. |
| Identifiers | **Device ID** | The identifier Apple gives apps from one developer (IDFV), sent to stop repeated free accounts and stored only as a keyed one-way code. Not the advertising identifier. |
| Purchases | **Purchase History** | Subscription product, dates, status and transaction identifiers, from RevenueCat. |
| Usage Data | **Product Interaction** | A record of each AI request: its kind, model, size and cost, used to apply plan limits and to cap spending. No content. |
| Diagnostics | **Other Diagnostic Data** | Short security and error records: which feature, an error code, a refusal kind. No content. |
| Other Data | **Other Data Types** | The network part of the IP address, stored only as a keyed one-way code, for abuse prevention. |

Leave every other type unticked. The ones a reviewer might expect, and why
they are not ticked:

| Type | Why not |
| --- | --- |
| Name | Sign in with Apple is asked for the email only, never the name (`SignInScreen.swift`). The optional name typed in onboarding stays on the phone, for the greeting (`Preferences.firstName`). |
| Photos or Videos | A photo or PDF is turned into text on the phone (`WorkExtractor`). Only the text is sent. |
| Coarse Location | The IP address is shortened and hashed, never turned into a place. |
| Customer Support | There is no support form in the app. A support email goes through the student's own mail app. See the note at the end. |
| Other Usage Data | Study-time records (`CompletionRecord`) and reminder history stay on the phone. |
| Crash Data, Performance Data | No crash reporter or analytics SDK. Supabase's SDK includes OpenTelemetry's API only to pass a trace header from a span the app starts; Albus starts none and has no exporter. |
| Browsing History, Search History | Study tools open in the browser outside Albus. Searching the tool list happens on the phone. |
| Payment Info | Apple takes the payment. Albus never sees card details. |

## 3. For each ticked type

App Store Connect asks three questions per type. The answers are the same for
all eight:

| Question | Answer |
| --- | --- |
| Purposes | **App Functionality** only. Not Analytics, not Product Personalization, not Developer's Advertising or Marketing, not Third-Party Advertising. |
| Is it linked to the user's identity? | **Yes.** Every one is stored with, or can be matched to, the account. Hashing the device identifier or the IP address does not make it unlinked, because the code is kept with the account. |
| Is it used for tracking? | **No.** Nothing is combined with other companies' data for advertising, and nothing goes to a data broker. |

Why App Functionality covers the security and cost records: Apple's
definition includes preventing fraud, implementing security measures and
minimising server costs.

## 4. Partners

The answers above already include them.

- **RevenueCat**: its SDK's own manifest declares Purchase History only. In
  Albus it is linked, because RevenueCat is given the account identifier
  (`PurchaseService.identify`).
- **Anthropic**: receives the plan or marking text from the server, not from
  the app. Covered by Other User Content.
- **Supabase**: hosts the database and functions. Its own operational logs may
  keep IP addresses and request details; the privacy policy says so. Those
  logs were not inspected (no production access).

## 5. Support email

The policy names a support address. A student who writes there chooses to, in
their own mail app, and Albus collects nothing through the app. That is why
Customer Support and Name are not ticked. If Albus ever adds a support form or
a "contact us" screen that sends from inside the app, tick Customer Support
(and Name, if it asks for one).

## 6. After answering

The App Store's privacy summary will read roughly: "Data Linked to You:
Contact Info, User Content, Identifiers, Purchases, Usage Data, Diagnostics,
Other Data" and "Data Used to Track You: none". That matches the policy's
"No ads, no advertising identifier and no tracking across apps or websites".

Re-check this page if any of these change: a new SDK, a support form, crash
reporting, or anything that sends a photo or file instead of its text.
