# App Store listing and review notes

Written 16 November 2026 for the build submitted on 23 November.

Checked against `main` at `1509386` together with the pull requests waiting to
merge that change what a student sees (#48 app wording, #51 tool names). If
either is not in the submitted build, re-check the lines marked **(#48)** and
**(#51)**.

Text in a code block is ready to paste into App Store Connect. Lengths were
counted, not estimated.

## App information

| Field | Paste this | Length |
| --- | --- | --- |
| Name | `Albus: Study Planner` | 20 of 30 |
| Subtitle | `Study plans that fit your week` | 30 of 30 |
| Primary category | Education | |
| Secondary category | Productivity | |
| Support URL | `https://albus-app.netlify.app/support/` | |
| Privacy Policy URL | `https://albus-app.netlify.app/privacy/` | |
| Marketing URL (optional) | `https://albus-app.netlify.app/` | |
| Licence agreement | Apple's standard one. Do not upload a custom one: the app and the terms page both say Apple's standard licence applies (`AppLinks.swift`, `website/terms/index.html`). | |

The website must be published before submission. On 14 November the live site
was still the 1 October version.

## Promotional text

118 of 170 characters. It can be changed later without a new review.

```text
Turn deadlines into a study plan that fits your week, see your next step, and rebuild the plan when your week changes.
```

## Keywords

97 of 100 characters. No competitor, tool or brand names, and no words already
in the name or subtitle, which Apple indexes separately.

```text
homework,revision,deadline,assignment,schedule,exam,rubric,essay,feedback,timetable,student,focus
```

## Description

```text
Albus turns your deadlines into a study plan that fits your week.

Add a task, say when it is due and roughly how long it will take. Albus breaks it into steps, places them in the hours you study, and rebuilds the plan when your week changes.

PLAN YOUR WORK
• Add a task with its deadline, the kind of work and your time estimate.
• Albus splits it into steps you can start straight away.
• Steps are written by AI when you are online and within your plan's allowance. Otherwise your phone makes the plan, so you always get one.

A WEEK THAT FITS
• Set your study hours and your days off.
• Albus schedules across all your tasks, and tells you when something no longer fits before its deadline.
• Miss a session and Albus moves the work to time you still have.

ONE STEP AT A TIME
• Open a step and start a focus timer.
• Tick steps off and watch each task move toward its deadline.
• Reminders for deadlines and for the day's first session are scheduled on your phone, with quiet hours you choose.

YOUR MARK SCHEMES
• Save the rubrics and mark schemes your teachers give you, and attach one to a task so its AI plan follows the criteria.

MARKING, ON PLUS AND PRO
• Paste your work, import a PDF or choose a photo. The text is read on your phone and sent for marking; the file or photo is not.
• With a rubric, Albus returns an estimated mark, a comment on each criterion and what to improve. Without one, it gives feedback without a mark.
• A mark from Albus is an estimate to help you improve. It is not your teacher's or an exam board's grade.

STUDY TOOLS
• A searchable list of more than 200 study tools. They are other companies' websites, and open in your browser when you choose one.

PLANS
• Free: 5 open tasks, 5 AI plans a week, 3 synced rubrics.
• Plus: 10 open tasks, unlimited AI plans within fair use, 5 synced rubrics, 2 markings a week.
• Pro: no plan limit on tasks or synced rubrics, unlimited AI plans within fair use, 5 markings a week.
Plus and Pro are auto-renewing subscriptions, monthly or yearly. Payment is taken from your Apple Account when you confirm. A subscription renews at the same price unless you cancel at least 24 hours before the period ends. Manage or cancel it in Settings on your iPhone, under your name, in Subscriptions.

GOOD TO KNOW
• You sign in with Apple. There is no password, and you can hide your email address.
• Your tasks are kept on your phone. Signing in on a new phone brings back your account and your subscription, not your tasks.
• No ads and no tracking.

Privacy policy: https://albus-app.netlify.app/privacy/
Terms of service: https://albus-app.netlify.app/terms/
Terms of use (EULA): https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
```

### What each claim rests on

| Claim | Where it is true |
| --- | --- |
| Steps by AI within the allowance, otherwise by the phone | `PlanCoordinator.addAssignment` plans on the phone first and replaces the steps when the AI answers; `PlanService.Failure.plansLocally`. |
| Tells you when something no longer fits | `PlanCoordinator.unplacedItems`; Home's "Some work still needs time". |
| Miss a session and the work moves | `PlanCoordinator.sweepMissedSessions`, run at launch and on return to the app (`AlbusApp.catchUp`). It can only move work to time that exists, which is why the sentence says "time you still have". |
| Reminders scheduled on the phone, with quiet hours | `NotificationScheduler`, `NotificationPlanner.movedOutOfQuietHours`; no push service. |
| An AI plan follows the rubric's criteria | `breakdown/index.ts` loads the attached rubric; `prompt.ts` `buildSystemPrompt`. Only for a rubric that has synced, and only for an AI plan. |
| Text read on the phone; file or photo not sent | `WorkExtractor`; `GradingService.Request` carries text only. |
| "Choose a photo" | The Grader opens the photo library (`photosPicker`), not the camera. Its row is labelled "Take a photo", which is audit finding A13. |
| Estimated mark, a comment per criterion, what to improve | `grade_prompt.ts`, `GradeResultView`. Without a rubric the server strips marks. |
| More than 200 study tools | 221 after **(#51)**, 225 before; `ToolCatalogTests` requires at least 200. |
| Plan limits | `public.plans` (`0034_three_plans.sql`, `20260915120000`) and the paywall's own list **(#48)**. |
| Fair use | `20260916090000_tighten_fair_use_ceilings.sql`; the hourly and daily limits in `public.plans`. |
| Tasks stay on the phone | `LocalAccount`; nothing downloads tasks. |
| No ads, no tracking | No ad or analytics SDK; `PrivacyInfo.xcprivacy` declares tracking false. |

### Left out on purpose

- No promise of better grades, and no "real grade" or "teacher-level" marking.
- No "unlimited" without "within fair use".
- No claim that tools differ by plan. They don't.
- No length for the free trial. The App Store shows the trial when the Apple
  Account is eligible, and the app shows it only then.
- No IB, AP or exam-board names. Albus is no longer an IB product.
- Nothing about syncing tasks between devices.
- No promise about how fast or how available marking is. See audit finding A2:
  at launch the shared AI budget allows about five rubric markings a day.

## Subscriptions

One group, `Albus`, with Pro above Plus (Pro is level 1).

Group display name (English):

```text
Albus
```

Each of the four products needs its own English localisation. The display name
is limited to 30 characters and the description to 45.

| Product ID | Display name | Description | Lengths |
| --- | --- | --- | --- |
| `com.felipegutierrez.albus.plus.monthly` | `Albus Plus Monthly` | `10 tasks, AI plans, 2 markings a week` | 18, 37 |
| `com.felipegutierrez.albus.plus.annual` | `Albus Plus Yearly` | `10 tasks, AI plans, 2 markings a week` | 17, 37 |
| `com.felipegutierrez.albus.pro.monthly` | `Albus Pro Monthly` | `No task limit, AI plans, 5 markings a week` | 17, 42 |
| `com.felipegutierrez.albus.pro.annual` | `Albus Pro Yearly` | `No task limit, AI plans, 5 markings a week` | 16, 42 |

The descriptions say "AI plans", not "unlimited AI plans": 45 characters leave
no room for "within fair use", and the word must not appear without it. This
replaces the wording in the owner's steps of September, which said "Unlimited
AI plans".

Each product needs a review screenshot: a capture of the paywall with that
plan's card selected. The ones in `Albus AI/3 App Store/Review screenshots/`
predate **(#48)**, so retake them from the submitted build.

Each product has a 3-day free trial as an introductory offer. The paywall says
"Start 3 days free" only when the App Store reports the offer and the Apple
Account is eligible (`RevenueCatStore.freeTrial`), so all four offers must
exist before submission.

## App Review information

### Sign-in required

Leave **Sign-in required** unticked, with no user name and no password. The
only way in is Sign in with Apple, so there is no account to hand over.

### Contact

First name, last name, phone and email are the owner's to fill in. The phone
number is in no file and must not be invented.

### Notes

```text
Albus is a study planner for students. Thank you for reviewing it.

SIGNING IN
Sign in with Apple is the only way to sign in, so there is no demo account to give you: your own Apple Account works, and you can hide your email. An account comes first because the study plans and the marking are written by an AI model on our server, and each account has its own limits on them, which reinstalling the app would otherwise reset. Nothing else is asked for: no password and no phone number.

FIRST RUN
1. Tap Continue with Apple.
2. Two short screens: your name (optional) and daily study hours, then a first task with a deadline.
3. Albus builds the first plan, shows one short screen about it, and opens Home.

BUYING A PLAN IN THE SANDBOX
Settings > See the plans. Choose Plus or Pro, monthly or yearly, and tap the button ("Start 3 days free", or "Subscribe to Plus" if the trial has been used). Confirm in Apple's sheet. The plans screen closes when our server has confirmed the plan, normally within a few seconds. If it says "Albus hasn't confirmed Plus yet", wait a moment and pull down on Settings to refresh.

PAID FEATURES
- Marking (Plus: 2 a week, Pro: 5 a week): Tools > Albus Grader. Paste a few paragraphs of text, or import a PDF or a photo, tap Continue, choose a rubric or "No extra rubric", and send. Marking takes up to a minute and returns an estimated mark with feedback. It can also be opened from a task.
- More open tasks: Free keeps 5 open, Plus 10, Pro has no plan limit. Add tasks with + on Home.
- AI plans: Free has 5 a week; Plus and Pro are unlimited within fair use. When the allowance is used, or offline, the phone makes the plan and says so.
- Synced rubrics: the Rubrics tab. Free syncs 3, Plus 5, Pro has no plan limit.

RESTORE AND MANAGE
- Restore: Settings > Restore purchases, and "Restore" at the bottom of the plans screen.
- Manage or cancel: Settings > Manage subscription (shown on a paid plan), or choose Free on the plans screen. Both open Apple's subscription sheet.
- Terms and Privacy are at the bottom of the plans screen and in Settings > About.

DELETING THE ACCOUNT
Settings > Delete account, at the bottom. Type DELETE, tap Permanently delete account, and confirm on Apple's sheet. The account and its content are deleted on our server, Sign in with Apple is revoked for Albus, and the phone is cleared. The screen warns that an Apple subscription has to be cancelled separately.

OTHER THINGS YOU MAY NOTICE
- Reminders are local notifications. Albus does not use push.
- The Tools tab lists other companies' study websites. Each opens in the browser only after you confirm.
- Marks are estimates, and the app says so wherever one is shown.
- The AI models are Anthropic's Claude models, called from our server. Students do not chat with a model: they get a study plan, or feedback on work they submit.
```

Before pasting, check three things against the submitted build:

1. The button labels under "Buying a plan" and "No extra rubric" **(#48)**.
2. That revoking Sign in with Apple is switched on: the owner has run
   `scripts/set-apple-secrets.sh`. Until then the server deletes the account
   without revoking (audit finding A7), and the sentence about revoking is not
   yet true.
3. That a sandbox purchase reaches the server: `REVENUECAT_APP_IDS` is set
   (audit finding A6). Until then the plans screen says "Albus hasn't
   confirmed Plus yet", and it never does.
4. That the reviewer can mark something. The AI budget shared by every paid
   and trial account allows about five rubric markings a day at launch
   (audit finding A2). If testers have used it that day, the reviewer sees
   "Albus is at capacity right now". The audit recommends raising the daily
   floor for the review window; decide that before submitting.

### If Apple asks for a demo account

Reply in the Resolution Center:

```text
Thank you. Albus has no user names or passwords: Sign in with Apple is the only sign-in method, so we cannot create a demo account that someone else can sign in to. Any Apple Account works, including a sandbox one, and nothing is requested beyond what Sign in with Apple shares. Every paid feature can be reached with a sandbox purchase from Settings > See the plans; the steps are in the review notes. If it would help, we can send a screen recording of the whole flow, from sign-in to purchase, marking, restore and account deletion.
```

### If Apple asks why an account is needed

```text
Albus's study plans and marking are generated on our server by an AI model, and each has a per-account allowance (for example 5 AI plans a week on the free plan). The account is what those allowances and the subscription belong to, and what the student deletes in Settings > Delete account. Sign in with Apple is the only method, it takes one tap, and the student can hide their email address. The app cannot produce an AI plan or a marking without a server request, so there is no account-free mode that would offer the same features.
```

## Age rating

Apple works out the rating from the questionnaire. These are the answers the
code supports. If the live form words a question differently, answer by the
"why" column.

| Question | Answer | Why |
| --- | --- | --- |
| Parental controls | No | No parent role or parent-managed limits. |
| Age assurance | No | The sign-in screen states an age rule; nothing verifies it. |
| Unrestricted web access | No | Tools open in the browser outside the app. There is no in-app browser. |
| User-generated content | No | Tasks, rubrics and work are private to the student. Nothing is shared or shown to others. |
| Social media | No | No feed, profiles, followers or sharing. |
| Social media switched off for under-13s | Not applicable | There is no social feature. |
| Messaging and chat | No | No communication between people. Students do not chat with the AI either: they receive a plan or feedback. |
| Advertising | No | No ads and no ad SDK. |
| Profanity or crude humour | None | Reminders are deadpan and contain no profanity (`Corpus*.swift`). |
| Horror or fear themes | None | |
| Alcohol, tobacco or drug use or references | None | |
| Medical or treatment information | None | |
| Health or wellness topics | None | The Tools list links to a few wellbeing websites. Albus has no health content of its own. |
| Mature or suggestive themes | None | |
| Sexual content or nudity | None | |
| Graphic sexual content and nudity | None | |
| Cartoon or fantasy violence | None | |
| Realistic violence | None | |
| Prolonged graphic or sadistic realistic violence | None | |
| Guns or other weapons | None | |
| Gambling | No | |
| Simulated gambling | None | |
| Contests | None | |
| Loot boxes | No | |

Two things the questionnaire cannot settle, for the owner to know:

- AI feedback is written about whatever a student submits. A refusal by the
  model is shown as a refusal (`anthropic.ts`), but nobody has reviewed a
  sample of real output for mature content. No paid model call was made for
  this document.
- The sign-in screen says students must be 13 or older, and under 16 need a
  parent's or guardian's agreement. The rating Apple derives from these answers
  will probably be lower than 13. The rating does not enforce the terms.

Do not choose the Kids category.

## Export compliance and content rights

- Encryption: the app uses only the operating system's encryption (HTTPS and
  the Keychain). `ITSAppUsesNonExemptEncryption` is `NO` in the build, so App
  Store Connect should not ask. If it does, the app qualifies for the
  exemption. See `verification.md`.
- Content rights: the Tools list shows other companies' names and logos, each
  only to identify the website it opens. So the answer to "does the app
  contain, show or access third-party content" is Yes. The next question asks
  you to confirm you have the rights to it. That confirmation is yours to
  make, not something this document can settle. What the code does: 170 of the
  221 tools show the site's own logo, fetched from the site
  (`scripts/tools/fetch_logos.py`); the rest show a lettered tile. If a
  company objects, its logo is removed (`scripts/tools/README.md`).
- Trader status under the EU's Digital Services Act is the owner's open
  decision and is not answered here.
