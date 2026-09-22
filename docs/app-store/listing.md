# App Store listing and review notes

Draft for the code audited at `ac63956`, 22 September 2026. Do not submit until
release gates in `verification.md` and `app-privacy.md` are resolved.

## Listing fields

- Name: **Albus**
- Subtitle: **Study plans that fit your week** (30 characters)
- Promotional text: **Turn deadlines into a realistic study plan. See your next step, make room for every subject, and adjust your schedule when life changes.**
- Keywords: `homework,revision,assignments,deadline,school,university,focus,timer,rubric,organization`
- Primary category: **Education**. Optional secondary: **Productivity**.
- Support: https://albus-app.netlify.app/support/
- Privacy: https://albus-app.netlify.app/privacy/
- URLs are intentionally not live yet. They must work before submission; this task does not publish them.

## Description

Make a study plan you can actually follow.

Albus helps you turn assignments and deadlines into smaller steps, then fits them
around the study hours you have available. Keep your subjects together in one
plan and see what needs your attention next.

PLAN YOUR WORK
Add a deadline, estimate the work and break it into manageable steps. AI-assisted
planning is available within your allowance, with on-device planning when the
service is unavailable or your planning allowance is reached.

MAKE ROOM FOR YOUR WEEK
Set your study hours and days off. Albus schedules across your assignments and
helps you adjust when your plans change. When work cannot fit, it tells you so.

FOCUS ON THE NEXT STEP
Open an assignment, follow its steps and use the focus timer to record a study
session. Mark steps complete and keep moving toward your deadline.

KEEP YOUR MARK SCHEMES CLOSE
Save your own rubrics and mark schemes for later reference. Browse a searchable
collection of study tools, with links that open in Safari when you choose them.

START WITHOUT A PASSWORD
Albus creates an anonymous account during setup. No email address or password is
required. Your local plans remain available offline; online features need a
connection.

Albus helps you plan your work. It does not guarantee grades or that every workload
will fit the time available.

## Claims intentionally omitted

No guaranteed grades, official curriculum coverage, unlimited AI, cross-device
work restoration, social/chat features or automatic calendar integration.
Do not advertise purchasable subscriptions or reachable paid marking in this
baseline: `PaywallScreen.purchase()` is empty and RevenueCat is not linked.
The grading implementation exists, but a new reviewer cannot buy access yet.
After the payment client is merged and sandbox-verified, add accurately qualified
paid-marking copy and Apple-required subscription terms. This document does not
pretend that dependency is already complete.

## App Review notes — paste only after release gates pass

Albus is a study planner. It uses anonymous accounts: no email, password or demo
login is required. On first launch, choose your study preferences, add the first
deadline and finish onboarding. The app creates its anonymous account at that
point. If a CAPTCHA is configured, complete the displayed challenge.

Feature paths:

1. **Planning:** Home → add an assignment; enter a title, work type, deadline and
   estimated time. Open the assignment to inspect/edit its steps and schedule.
2. **Focus:** open a scheduled step from an assignment and start its focus session;
   finish it to record the study time and update progress.
3. **Rubrics:** Rubrics tab → add a rubric; enter your own mark scheme and save it.
4. **Study tools:** Tools tab → search/filter → select a tool → confirm opening
   Safari. These external services are independent of Albus.
5. **Preferences:** Settings → study hours, days off and reminder preferences.
   Reminders are local notifications, not a remote push service.
6. **Marking, once purchases are enabled:** Tools → Albus Grader (or the grading
   action on an assignment). Select your own rubric where appropriate; paste
   text or select a document/photo for on-device text extraction, then request
   marking. The extracted text is sent to the AI provider; grades are guidance.
7. **Subscription review, once payments/app is merged:** use Apple's sandbox
   purchase environment with a sandbox Apple account. The Apple account is for
   the purchase only; Albus still uses anonymous authentication. Verify Settings
   → Restore purchases and Manage subscription. Do not supply a production
   customer account or expect a production charge.
8. **Account deletion (requires the owner's deployed migration):** Settings → Delete
   account → type DELETE → confirm. The screen warns that Apple subscriptions
   must be cancelled separately in iPhone Settings → your name → Subscriptions.

No account/password credentials should be entered in the review login fields.
The developer must provide their own App Review contact details in App Store
Connect; fgutort8@gmail.com is the approved support email. A required phone number
has not been supplied and must not be invented.

## Age-rating questionnaire

Use the live questionnaire; Apple derives the rating and regional variants.
Do not promise a numeric rating before completing it. Source:
[Apple's category definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions).

| Question / content descriptor | Proposed answer | Code basis / qualification |
| --- | --- | --- |
| Parental controls | No | No parent role or parent-managed feature limits. |
| Age assurance | No | No age verification or declared-age-range API. CAPTCHA is not age assurance. |
| Unrestricted web access | No | Tools open external Safari; CAPTCHA is a fixed widget, not an address-bar browser. |
| User-generated content | No under Apple's distribution definition | Work/rubrics are private to the student; no public sharing/feed. This does not mean no private user content is collected. |
| Social media | No | No feed or redistribution. |
| Social media disabled under 13 | Not applicable | No social-media feature or age gate. |
| Messaging/chat between users | No | No person-to-person communication feature. |
| Advertising | No | No ad display or ad SDK. |
| Profanity/crude humor | None in authored content | No authored examples; model output and arbitrary student input are not exhaustively verified. |
| Horror/fear themes | None in authored content | Planner/rubric UI has no such content. |
| Alcohol/tobacco/drug references | None in authored content | Not an intended content category. |
| Medical/treatment information | None in authored content | Not a medical advice feature. |
| Health/wellness topics | No | Study planning/focus is not a health programme. |
| Mature/suggestive themes | None in authored content | No authored mature content. |
| Sexual content/nudity | None in authored content | No authored sexual content. |
| Graphic sexual content/nudity | None | Not an app feature. |
| Cartoon/fantasy violence | None | Decorative cactus animation is not violence. |
| Realistic violence | None in authored content | No authored violent scenes. |
| Prolonged graphic/sadistic violence | None | Not an app feature. |
| Guns/other weapons | None in authored content | No weapon content. |
| Gambling | No | No betting or cash-prize mechanism. |
| Simulated gambling | None | No gambling simulation. |
| Contests | None | No competition/prize system. |
| Loot boxes | No | No random paid rewards. |

These content-frequency answers describe authored app content, not an assurance
that arbitrary student submissions or AI output can never contain a mature topic.
Before final submission, the owner must assess the release model's actual safety
behaviour and content the feature can surface. This task made no paid model calls.
Do not claim a Kids Category product or an enforced minimum age; neither exists.
