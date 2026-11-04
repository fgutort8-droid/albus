# Validation and rerun instructions

## Scope

The source-only comparison checks all changed Swift files against `48185b6`, ignoring displayed string contents, comments and whitespace. Its only structural exceptions are the three owner-authorized removed paywall perk tuples and the reference-price text interpolation. Notification template IDs, metadata and required placeholder sets are preserved. All 29 changed Swift files pass. Protected paths, dependencies, project configuration and server code are unchanged.

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
