# Screenshots

Written 16 November 2026. No listing screenshots exist yet. The two in
`Albus AI/3 App Store/Review screenshots/` are paywall captures for the
subscription review, from September; they predate the paywall wording in #48,
so retake them too.

Take every screenshot from the build that will be submitted (the weekend of
21–22 November), after the wording pull requests have merged. A screenshot
taken earlier can show text the app no longer has.

## Size

One set, 6.9-inch, portrait, 1320 × 2868 pixels, no transparency. App Store
Connect scales it down for smaller iPhones. Use the **iPhone 17 Pro Max**
simulator (`8B7631E9-1DA0-4933-848E-A643A2F469CD`), whose screenshots are that
size. Check each file's size before uploading:

```bash
sips -g pixelWidth -g pixelHeight -g hasAlpha screenshot.png
```

## The set, in order

Six screenshots. The caption is optional text to put above the app's screen
if a designed frame is used; each one is true of the app as it is. With no
frame, upload the plain captures in the same order.

| # | Screen | What must be on it | Caption |
| --- | --- | --- | --- |
| 1 | Home | Three or four tasks in different subjects, today's steps listed | `Your deadlines, planned into your week` |
| 2 | A task opened (TaskDetailScreen) | Its steps spread over several days before the deadline | `Every task split into steps you can start` |
| 3 | Rubrics tab, with a rubric opened | A rubric with three or four criteria | `Plans that follow your mark scheme` |
| 4 | Focus timer (FocusModeScreen) | A step running | `One step at a time` |
| 5 | Marking result (GradeResultView) | A real result from a sandbox marking: estimated mark, criteria, what to improve | `Feedback on your work, on Plus and Pro` |
| 6 | Month calendar (MonthCalendarScreen) | Deadlines and study days across the month | `See the whole month at a glance` |

Why these and not others:

- **Not the Tools tab.** It is a wall of other companies' logos. Showing them
  in the App Store's own artwork invites a trademark question in review, and
  the tools are other websites, not Albus. The listing describes them in words.
- **Not the paywall, the sign-in screen or Settings.** They show nothing a
  student would choose the app for.
- **Screenshot 5 says "on Plus and Pro"**, because marking is paid and the
  screenshot must not suggest it is free. It needs a genuine result: a
  sandbox purchase on a TestFlight build, then one marking. Never a made-up
  score, and never one written by hand into the app. If no real result is
  available in time, leave screenshot 5 out and upload five.

## Content to type in

Use invented tasks and subjects. No real names, schools or teachers. Deadlines
must be in the future on the day of capture, and spread over two or three
weeks so the plan has something to show. For example:

| Subject | Task | Deadline | Estimate |
| --- | --- | --- | --- |
| History | Essay: causes of the First World War | in 12 days | 6 hours |
| Biology | Lab report: enzyme activity | in 6 days | 3 hours |
| Maths | Problem set 4 | in 3 days | 2 hours |
| English | Read chapters 5–8 and write notes | in 9 days | 4 hours |

For screenshot 3, a rubric such as "Essay rubric" with criteria "Argument",
"Use of evidence", "Structure" and "Style", each out of 5.

## How to capture without an account (screenshots 1, 2, 3, 4 and 6)

This uses a Debug build and makes no server calls, so nothing is paid for and
no account is made. The debug switches below are compiled out of the release
build (`#if DEBUG`).

1. In a worktree of the final commit, copy `ios/App/Config.example.xcconfig`
   to `ios/App/Config.xcconfig` (the example has no keys, so the app has no
   server and its phone planner makes every plan), then run
   `xcodegen generate --spec project.yml` in `ios/`.
2. Build for the iPhone 17 Pro Max simulator and launch with
   `-albus.debug.assumeSignedIn -albus.debug.forcePlan pro
   -albus.debug.skipNotificationPrompt -albus.profile.onboarded YES`.
   `forcePlan pro` only lifts the open-task limit so four tasks fit; it buys
   nothing.
3. Set the simulator's clock in the status bar to 9:41 and full battery:
   `xcrun simctl status_bar 8B7631E9-1DA0-4933-848E-A643A2F469CD override --time 9:41 --batteryState charged --batteryLevel 100`.
4. Add the tasks above with + on Home, and the rubric on the Rubrics tab.
5. Capture each screen with
   `xcrun simctl io 8B7631E9-1DA0-4933-848E-A643A2F469CD screenshot 1-home.png`.
6. Look at every image before uploading: no debug text, no placeholder, and
   the plan reads sensibly.

These steps are made by the phone's own planner, which is real app output.
Albus may show a short note saying the plan was made on the phone; that is
true and can stay in the picture. No caption may say these steps were written
by AI.

## Screenshot 5 and the subscription review screenshots

Both need the TestFlight build and a sandbox Apple Account:

- Screenshot 5: buy Plus in the sandbox, mark a short invented essay against
  the rubric from screenshot 3, and capture the result.
- Review screenshots, one per product: open the plans screen with that plan
  and billing period selected, and capture it. These go with each product in
  App Store Connect, not in the listing.
