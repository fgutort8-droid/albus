# Validation and rerun instructions

## Scope

The source-only comparison checks all changed Swift files against `48185b6`, ignoring displayed string contents, comments and whitespace. Its only structural exceptions are the three owner-authorized removed paywall perk tuples, the reference-price text interpolation, and the Settings AI-plans label, which says fair use only when the allowance is unlimited. Notification template IDs, metadata and required placeholder sets are preserved. All 29 changed Swift files pass. Protected paths, dependencies, project configuration and server code are unchanged.

The comparison is a focused guard for this diff, not a general Swift parser. Compilation and the existing unit tests provide the additional validation. The audit generator resolves every referenced evidence anchor and recreates the inventory, exact changes, claim table, notification table and external-catalogue appendix without network access.

## Commands

Run from this worktree, with no other `xcodebuild` running on the Mac:

```sh
cd ~/Developer/albus-app-wording
python3 docs/app-wording/build_report.py
python3 docs/app-wording/verify_scope.py
swift test --package-path ios/AlbusCore --scratch-path /tmp/albus-wording-core-dd
cd ios
xcodegen generate --spec project.yml
xcodebuild test -onlyUsePackageVersionsFromResolvedFile \
  -project Albus.xcodeproj -scheme Albus \
  -destination 'id=A6DB1461-0588-4341-ACDF-73CF87F44024' \
  -only-testing:AlbusTests -derivedDataPath /tmp/albus-wording-dd \
  SUPABASE_URL= SUPABASE_PUBLISHABLE_KEY= \
  REVENUECAT_API_KEY= REVENUECAT_TEST_API_KEY=
```

The four empty build-setting overrides deliberately disable the test host's live service configuration. The app normally starts entitlement work during launch, so the task's bare command would not sufficiently protect the no-live-server rule. The compiled app's four corresponding Info.plist values were checked to be empty; `Config.xcconfig` itself was never read, printed, copied or edited. This does not change shipped source or configuration. Unit HTTP tests use mocked URL protocols. No real sign-in, purchase, grading or planning request was made.

`-only-testing:AlbusTests` excludes execution of `AlbusUITests`. Xcode may compile the UI-test bundle as part of scheme preparation, but no UI test was run. AlbusCore's package has no third-party dependencies and its tests are local.

For the opt-in paywall captures, use the same command with `-only-testing:AlbusTests/PaywallSnapshots` instead, and set the runner environment before it:

```sh
TEST_RUNNER_ALBUS_SNAPSHOT_DIR=/tmp/albus-wording-snapshots xcodebuild test \
  -onlyUsePackageVersionsFromResolvedFile \
  -project Albus.xcodeproj -scheme Albus \
  -destination 'id=A6DB1461-0588-4341-ACDF-73CF87F44024' \
  -only-testing:AlbusTests/PaywallSnapshots \
  -derivedDataPath /tmp/albus-wording-dd \
  SUPABASE_URL= SUPABASE_PUBLISHABLE_KEY= \
  REVENUECAT_API_KEY= REVENUECAT_TEST_API_KEY=
```

## Results and visual check

The exact summaries and exit codes for every run are in [test-results.txt](test-results.txt). Full iOS runs skip 10 opt-in snapshot tests by design. The separate six-test paywall run enables all six paywall captures; each image was inspected at 393 × 852. The updated card pitches, trial/price captions and visible perk text fit the captured viewport. This is not a full scroll-content, device-size or Dynamic Type audit. Changes after those captures did not affect paywall copy or layout.

Snapshots remain under `/tmp/albus-wording-snapshots/`: `1-free-monthly-trial.png`, `2-free-yearly-trial.png`, `3-free-no-trial.png`, `4-no-store.png`, `5-pro-to-plus.png`, `6-plus-to-free.png`. They are temporary review artifacts, not checked-in baseline changes. Existing headline and marking-failure assertions were updated, without weakening their behavior checks.

The pre-commit hook reported that Gitleaks is not installed and skipped its local secret scan. No dependency was installed. No secret file was opened or added.

## Cleanup

After reviewing results, remove only this task's generated build directories:

```sh
rm -rf /tmp/albus-wording-dd /tmp/albus-wording-core-dd
```

Both directories were removed after the final successful runs. Compact test output is committed here; the full logs and six PNGs remain in `/tmp` for this session. No push or PR was performed.

## Re-verification by Claude Code, 4 November 2026

Run in this worktree at `3e6199d`, then again after the fixes below.

- `build_report.py` reproduced every committed audit file at `3e6199d` exactly (no `git diff`), and `verify_scope.py` passed all 29 Swift files.
- A separate parser compared all 115 notification templates with `48185b6`. IDs, kind, workload, register and placeholder sets are identical. Every title is at most 40 characters and every body at most 110, with no exclamation marks. 61 texts changed.
- The whole Swift diff against `48185b6` was read line by line, not only the report.
- The 4 November section of `website/privacy-audit.md` on `main` (`1509386`) agrees with the app copy. The subject name is never sent to the AI, so “pitch answers at the right level” was false. “Fair use” and “estimate” match the terms. The retained payment and security records on the deletion screen match the privacy policy. Anonymous accounts cannot exist on the new project, so the two “Add Apple” lines shown only to anonymous accounts are unreachable but accurate.
- In place of the skipped Gitleaks scan, the branch diff was searched for Anthropic, Supabase, Stripe and RevenueCat key formats, JWTs, private keys, and the project and team IDs. Nothing was found. `ios/App/Config.xcconfig` is ignored and untracked.

Fixes added in this commit:

- `SettingsScreen.swift`: the AI-plans row said “(fair use)” on Free too, where five a week is a plan limit. The label now says fair use only when the allowance is unlimited.
- `GraderScreen.swift`: the marking meter's no-limit branch said “Unlimited”. No plan has unlimited marking, so it now says “No plan limit”, as Settings does.
- `GraderScreen.swift`: the comment above the waiting lines still described the old step-by-step lines.
- `reported.md`: four new owner items. They are the rubric wording on the website, the days phrase in quiet-app reminders, the Plus badge, and four tool names that point elsewhere.

Results after the fixes:

```text
swift test (AlbusCore): Test run with 120 tests in 25 suites passed after 0.630 seconds.
xcodegen exit: 0
xcodebuild test -only-testing:AlbusTests, four service overrides empty:
Test run with 339 tests in 41 suites passed after 53.223 seconds. ** TEST SUCCEEDED ** exit code: 0
```

The built test app's four service values in `Info.plist` were checked to be empty, without printing them. No UI test, sign-in or live call ran. `/tmp/albus-wording-dd` and `/tmp/albus-wording-core-dd` were removed afterwards.
