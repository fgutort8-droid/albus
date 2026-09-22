# 6.9-inch screenshot plan

Use iPhone 17 Pro Max **9BBC0A52-ECD1-448E-8CCE-733DE59441C8** only.
Do not use Claude's A52DA30D simulator. Do not create production accounts or call
paid AI. Do not publish screenshots or the website from this task.

[Apple's current screenshot specification](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications)
accepts portrait 1320 × 2868 pixels for the 6.9-inch slot (also other specified
sizes), one to ten images, with no alpha channel. Check actual exported dimensions
and alpha; do not assume a simulator name establishes them.

| Order | Real app screen | Message it can honestly support |
| --- | --- | --- |
| 1 | Home with three sample assignments | Keep multiple subjects in one planner. |
| 2 | Assignment detail with its scheduled steps | Turn one deadline into manageable steps. |
| 3 | Tools directory | Find a study tool and choose whether to open Safari. |
| 4, optional later | Focus session | Work on the next step with a timer. |
| 5, after paid access is verified | A genuine grading result | Feedback against your own mark scheme. Do not invent a score or label fixture feedback as a real model result. |

The first three can use the existing `SeedData` preview assignments. These are
fictional student work, not official curriculum data or claimed AI results. They
are rendered by the actual app and scheduler, without adding marketing overlays.
Do not capture the unfinished purchase controls for the public listing.

## Capture attempt and safe next attempt

The initial simulator build succeeded. An opt-in XCTest screenshot attempt then
stalled before reaching the app. It was terminated; the log ended with
`** BUILD INTERRUPTED **`. Direct launch on the assigned device returned:

```text
com.apple.CoreSimulator.SimError, code=405
Unable to lookup in current state: Shutting Down
```

No usable screenshots were produced. The experimental fixture hook and capture
test were removed rather than shipping unused capture machinery. No simulator
reset, global process kill, or action on Claude's device was performed.

Once this simulator is healthy, use placeholder Config.xcconfig and the existing
`-albus.debug.assumeSignedIn -albus.profile.onboarded YES` arguments to enter the
real app without an account. Enter fictional assignments through the app's UI;
with Backend.shared nil, its existing on-device planner can build their steps.
Do not use the owner's real backend config. Capture the three screens above with
`xcrun simctl io 9BBC0A52-ECD1-448E-8CCE-733DE59441C8 screenshot <path>` and inspect
each image, dimensions and alpha before accepting it. A paid grading result must
wait for a separate authorized and genuine marking run.
