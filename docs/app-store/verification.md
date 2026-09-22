# Submission verification

This work lives only on `codex/submission-readiness`, created from `origin/main`
at `1a082b1`, then rebased onto `ac63956` after the owner's #2/#5 merges. Other agents' branches and checkouts are not modified.

## Privacy API audit

Read Apple's official [API category list and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
on 22 September 2026, including its machine-readable documentation. The source
scan covered `ios/App/Albus` and `ios/AlbusCore/Sources`, excluding tests and SDKs.

| Category | App-owned result | Manifest decision |
| --- | --- | --- |
| User defaults | `Preferences`, `SessionStorage`, `NotificationState`, `PendingDeletions` read/write app-owned keys. No MDM/shared-app-group/global-domain access found. Account-deletion preferences use the same scope. | `NSPrivacyAccessedAPICategoryUserDefaults`, `CA92.1` (app-private storage). |
| File timestamps | No `creationDate`, `modificationDate`, `fileModificationDate`, content/creation-date resource keys, stat-family or getattrlist calls found. | Not declared. `WorkExtractor` reads `fileSizeKey` for a selected document; that accessor is not on Apple's required-reason API list. `fileExists`, copying/removing files and a Date-based quarantine filename do not read file timestamps. |
| System boot time | No `systemUptime` or `mach_absolute_time` calls found. Timers use ordinary Date/Timer/task scheduling. | Not declared speculatively. |
| Disk space | No volume-capacity keys, filesystem free-size/system-size, statfs/statvfs calls found. | Not declared. A selected file's size is not free disk capacity. |
| Active keyboards | No `activeInputModes` calls found. | Not declared. Text input alone is not a reason to declare this API. |

No tracking domains; tracking is false. Seven app-collected data categories are
linked for functionality; the complete mapping and partner caveats are in
`app-privacy.md`. The manifest does not claim to anonymise account/device IDs.

## Export compliance

`ITSAppUsesNonExemptEncryption = NO` is generated from `ios/project.yml` into
Info.plist. [Apple's export guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
allows an exempt declaration for operating-system encryption.

Inspected app networking: `Backend.swift` uses URLSession and system HTTPS;
`CaptchaService.swift` uses WKWebView HTTPS; auth storage delegates to system
Keychain via `SessionStorage.swift`. No custom cipher, VPN, bundled TLS library,
end-to-end encryption or app-owned CryptoKit/CommonCrypto implementation found.

Resolved Supabase Auth contains PKCE SHA-256 hashing and system
`SecKeyVerifySignature` for token integrity, not custom content encryption.
Its Swift Crypto dependency uses Apple's CryptoKit on iOS; its Package.swift
restricts the BoringSSL-backed implementation to other platforms in the normal
build. CryptoSwift/secp256k1 references in Supabase's package are test dependencies,
not Albus app targets. Server-side HMAC hashing in Deno is not bundled iOS code.
The declaration means **no non-exempt encryption**, not “no cryptography”.
Re-audit if payment or other dependencies add an independent encryption engine.

## Built bundle inspection

Command:

```sh
python3 scripts/verify-app-privacy.py \
  /tmp/albus-submission-derived/Build/Products/Debug-iphonesimulator/Albus.app
```

Observed after a successful simulator build:

```text
PASS: built app manifest matches source; tracking=false; ITSAppUsesNonExemptEncryption=false.
Manifest: PrivacyInfo.xcprivacy
Manifest: swift-crypto_Crypto.bundle/PrivacyInfo.xcprivacy
```

The manifest was automatically copied by xcodegen's existing `App/Albus` source
entry. The verification step now runs against CI's built app as well.

The assumption that both SDKs already ship manifests was **not confirmed**:

- Supabase resolved to **2.55.2**. A recursive source and built-bundle inventory
  found no Supabase PrivacyInfo.xcprivacy. Do not relabel Swift Crypto's manifest
  as Supabase's. No required-reason calls from Apple's five categories were found
  in Supabase's own Sources during this audit. This is source inspection, not a
  promise that Apple's upload analysis accepts every transitive SDK.
- Swift Crypto's own manifest **is** bundled and parses successfully.
- RevenueCat is **not a dependency of the current main-based app**. Its manifest
  cannot be verified in this build. After PR #3 lands, rebuild and inspect the
  actual app bundle before claiming it is present. Do not add a fake vendor
  manifest or pull in unmerged payment changes for this check.

Only a simulator build is checked here. Repeat the same script against the
Release `.xcarchive/Products/Applications/Albus.app` before uploading. A signed
archive and App Store validation were not run; no Apple Team ID was used.

## Negative checks actually run

Two temporary fake bundles exercised the new verifier:

```text
Missing encryption declaration rejected: AssertionError: export-compliance property missing/incorrect
Stale bundled manifest rejected: AssertionError: bundled privacy manifest differs from source
Violating fixtures discarded.
```

`plutil -lint`: PrivacyInfo.xcprivacy: OK.
Metadata length checks: subtitle 30/30; promotional text 136/170; keywords 88/100.

## Release gates and limits

- The policy URLs must become publicly accessible before submission; no website
  publication occurred in this task.
- Payment purchase/restore controls are still stubs on the starting main revision.
  Review notes explicitly mark their payment-client dependency.
- Account deletion and payments backend are now merged on the audited base.
  Backend migration deployment belongs to the owner; this branch does not deploy.
- Resolve the policy/partner questions in `app-privacy.md`, particularly optional
  Cloudflare CAPTCHA, provider logging, and operational support emails.
- Final AI-content age-rating answers need release-model assessment. No paid
  model call, production account creation or production request was used here.
- Local source findings are not presented as production configuration inspection.

Screenshot stretch: no usable captures. XCTest stalled before the app ran and was
terminated; direct launch then returned CoreSimulator error 405 (Shutting Down).
The temporary capture code was removed. `screenshots.md` retains the plan and
safe procedure. This is not reported as a successful UI test.

## Final local build observed

After rebasing onto `ac63956`, `xcodebuild build-for-testing` on the designated
9BBC0A52 simulator destination ended with `** TEST BUILD SUCCEEDED **`. The log
shows the app manifest being copied and the app plus both test targets compiling.
The bundle verifier then passed again against that build, not the original tree.

Resolved dependencies: Supabase 2.55.2 (`40344fb3a7007d772218c6ddf6bca9febd8cb226`),
Swift Crypto 4.5.2 (`da9d28d69ebe3894b18376c8f2395c2f37b8448f`). The Swift Crypto
manifest parses with tracking false and empty collected-data/API arrays.
`otool -L` shows system CryptoKit and Security frameworks in the built app.
No standalone app-owned cipher was found. These observations support the source
export-compliance assessment; they are not an App Store upload validation.

Local test execution is not claimed: the screenshot test could not launch.
The PR's CI run is the app/core/backend test authority for this change.
