# What was checked for submission, and how

Written 16 November 2026. Checked against `main` at `1509386` with the six open
pull requests (#48–#53) merged on top in a scratch worktree. No production
system was read or written, no account was made, and no paid AI call was made.

## Privacy manifest

`ios/App/Albus/PrivacyInfo.xcprivacy` declares tracking false, no tracking
domains, eight collected data types (all linked, all App Functionality, none
for tracking), and one required-reason API: user defaults, reason `CA92.1`
(the app's own storage). The answers in `app-privacy.md` are the same eight.

The bundle verifier was run against the latest simulator build (from
`fix/marking-capacity-message`, which is `main` plus one Swift file):

```text
$ python3 scripts/verify-app-privacy.py .../Debug-iphonesimulator/Albus.app
PASS: built app manifest matches source; tracking=false; ITSAppUsesNonExemptEncryption=false.
Manifest: PrivacyInfo.xcprivacy
Manifest: RevenueCat_RevenueCat.bundle/PrivacyInfo.xcprivacy
Manifest: swift-crypto_Crypto.bundle/PrivacyInfo.xcprivacy
```

RevenueCat's own manifest is now in the app (in September it was not yet a
dependency). It declares Purchase History, unlinked, for App Functionality.
Albus answers it as linked, because RevenueCat is given the account's
identifier.

Supabase's SDK ships no manifest of its own. It pulls in OpenTelemetry's API
only, to pass a trace header from a span the app has started. Albus starts no
spans and links no exporter, so it sends nothing.

Resolved SDK revisions (`ios/Package.resolved`): supabase-swift `40344fb3a700`,
purchases-ios-spm `d654b8b85143`, swift-crypto 4.5.2, opentelemetry-swift-core
2.5.0.

## Required-reason APIs

Searched `ios/App/Albus` and `ios/AlbusCore/Sources` on 16 November:

| Category | Found | Declared |
| --- | --- | --- |
| User defaults | Ten files read and write the app's own keys. No shared suite. | Yes, `CA92.1`. |
| File timestamps | None. | No. |
| System boot time | No `systemUptime` or `mach_absolute_time`. The focus timer measures elapsed time with Swift's `ContinuousClock` (`FocusSession.swift`). | No. See below. |
| Disk space | None. | No. |
| Active keyboards | None. | No. |

`ContinuousClock` is not on Apple's list, so it is not declared. If the
TestFlight upload brings an email from Apple naming "System boot time APIs"
(ITMS-91053), the fix is one entry in the manifest:
`NSPrivacyAccessedAPICategorySystemBootTime` with reason `35F9.1` (measuring
time between events in the app). The verifier compares the built manifest
with the source one, so it needs no change. Read that email when the first
build is uploaded.

## Export compliance

`ITSAppUsesNonExemptEncryption` is `NO`, generated from `ios/project.yml`
into the app's Info.plist and confirmed in the built app above. The app's
networking is the system's HTTPS (`URLSession`), and the session is stored in
the system Keychain (`SessionStorage.swift`). The only cryptography in the
app's own code is a SHA-256 hash of the Sign in with Apple nonce
(`SignIn.swift`), which is authentication, not encryption. So App Store
Connect should not ask; if it does, answer that the app uses only exempt
encryption.

## Debug switches

Every `-albus.debug.*` launch argument (`assumeSignedIn`, `forcePlan`,
`supabaseURL`, and the others) sits inside `#if DEBUG`, so none exists in the
release build a student downloads.

## Listing text

Counted from `listing.md` by script, not by eye:

| Field | Characters | Apple's limit |
| --- | --- | --- |
| Name | 20 | 30 |
| Subtitle | 30 | 30 |
| Promotional text | 118 | 170 |
| Keywords | 97 | 100 |
| Description | 2,717 | 4,000 |
| App Review notes | 2,856 | 4,000 |
| Subscription descriptions | 37 and 42 | 45 |

Every on-screen label the review notes quote was found in the app's code:
"See the plans", "Restore purchases", "Manage subscription", "Delete
account", "Permanently delete account", "No extra rubric", "Albus Grader",
"Subscribe to", "Restore", and the purchase message "Albus hasn't confirmed
Plus yet". "Continue with Apple" is Apple's own button
(`SignInWithAppleButton(.continue)`). "Start 3 days free" is built from the
trial Apple reports (`PaywallScreen.callToAction`), so it shows only once the
trials exist in App Store Connect.

## Not checked here

- A Release archive. Run the same verifier against
  `Albus.xcarchive/Products/Applications/Albus.app` before uploading.
- App Store Connect's own validation of the upload.
- Supabase's production logging and retention settings.
- Real AI output for mature content (relevant to the age rating), since no
  paid call was allowed.
- Screenshots, which must come from the final build (`screenshots.md`).
