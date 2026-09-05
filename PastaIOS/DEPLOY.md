# Deploying PastaIOS to TestFlight

The iOS companion app ships through `.github/workflows/release-ios.yml`. The
workflow archives `PastaIOS/PastaIOS.xcodeproj` (scheme `PastaIOS`, bundle id
`com.pasta.ios`, team `8X4ZN58TYH`) for `generic/platform=iOS`, exports an App
Store Connect IPA using `PastaIOS/ExportOptions.plist`, and uploads it (with
dSYMs) to App Store Connect using an App Store Connect API key. Apple then
processes it into TestFlight.

Signing is **manual**: an Apple Distribution certificate and an App Store
provisioning profile are supplied as secrets. This mirrors the `Release` build
settings already checked into `PastaIOS.xcodeproj` (`Apple Distribution` +
`PastaIOS_AppStore_CloudKit_v2`) and the lane that is proven in sibling
projects. The API key is used only for the upload, so it does not need the
Admin role.

## Required GitHub repository secrets

Add all seven under **Settings → Secrets and variables → Actions**. The
workflow's first step fails with the exact list of anything missing.

| Secret | Value | Where it comes from |
|---|---|---|
| `APP_STORE_CONNECT_KEY_ID` | The 10-character key id, e.g. `AB12CD34EF` | App Store Connect → Users and Access → Integrations → App Store Connect API → Team Keys |
| `APP_STORE_CONNECT_ISSUER_ID` | The issuer UUID shown above the key list | Same page |
| `APP_STORE_CONNECT_API_KEY` | The `.p8` private key, base64 encoded: `base64 -i AuthKey_<KEY_ID>.p8 \| pbcopy` | Downloaded once when the key is created. Role: **App Manager** (or Developer) is enough |
| `APPLE_TEAM_ID` | `8X4ZN58TYH` | Already present; the macOS `release.yml` uses it for notarisation |
| `IOS_DISTRIBUTION_P12` | Apple Distribution certificate **with private key**, base64: `base64 -i dist.p12 \| pbcopy` | Keychain Access → My Certificates → right-click `Apple Distribution: …` → Export as `.p12`. Must be the cert that signs the builds you upload today, or a new one created at developer.apple.com → Certificates |
| `IOS_DISTRIBUTION_PASSWORD` | The password chosen when exporting the `.p12` | You |
| `IOS_APPSTORE_PROFILE` | App Store distribution provisioning profile for `com.pasta.ios`, base64: `base64 -i PastaIOS_AppStore_CloudKit_v2.mobileprovision \| pbcopy` | developer.apple.com → Profiles. Distribution → App Store Connect. Must be generated for the certificate in `IOS_DISTRIBUTION_P12`, and the `com.pasta.ios` App ID must have **iCloud (CloudKit)** and **Push Notifications** enabled |

Before building, the workflow decodes the profile and refuses to continue if it
is for a different team or bundle id, lists devices (i.e. is not an App Store
profile), has expired, or does not grant the `iCloud.com.pasta.ios` container
or `aps-environment`.

Nothing else is needed. The workflow never reads Apple ID passwords.

## How a release happens

1. Merge to `main`. `ci.yml`'s `auto-release` job derives the next semantic
   version from the conventional-commit messages and pushes a `vX.Y.Z` tag —
   but only if every CI suite on that push was green (macOS tests + launch
   smoke, iOS XCUITests, appcast contract, landing e2e when it ran). A red
   suite means no tag and therefore no release of either app.
2. That tag triggers both `release.yml` (macOS DMG, Sparkle, Homebrew) and
   `release-ios.yml` (TestFlight). The two are independent; an iOS failure does
   not block the macOS release and vice versa.
3. `release-ios.yml` first runs the **`preflight`** job: the full XCUITest e2e
   suite on an iPhone simulator, via `scripts/ci-ios-e2e.sh` — the very same
   script and steps as `ci.yml`'s `ios-e2e` job, so the two cannot drift. The
   `testflight` job `needs: preflight`; nothing is archived, let alone
   uploaded, if the suite fails. Its result bundle and crash logs are attached
   as the `release-ios-preflight-diagnostics` artifact on failure.
4. `testflight` then sets `MARKETING_VERSION` to the tag (`v1.5.0` → `1.5.0`)
   and `CURRENT_PROJECT_VERSION` to the build number described below, archives,
   verifies the archive's bundle id / version / build / iCloud container, then
   independently requires successful main CI for that exact commit across every
   surface, then exports and uploads. Main must still match the commit or be an
   appcast-only descendant. This applies to automatic and manual tags/uploads.
5. After the upload, `scripts/ci-asc-wait-for-build.sh` polls the App Store
   Connect API (a JWT minted from the same `APP_STORE_CONNECT_*` secrets) every
   60 s for up to 20 minutes until the build's `processingState` is `VALID`.
   `INVALID`/`FAILED` fails the job and prints the build's attributes; a
   timeout also fails because acceptance remains unverified. The upload may
   still complete: inspect the existing build or rerun only the polling script,
   rather than re-uploading the same build number.
   Once `VALID`, the build is under the app's TestFlight tab; internal testers
   get it automatically, external groups need the usual review.

Runs are serialised (`concurrency: release-ios`) so two tags pushed close
together cannot race App Store Connect.

### Manual runs and dry runs

**Actions → Release iOS (TestFlight) → Run workflow** lets you:

- `version`: override the marketing version. Defaults to the latest `v*` tag
  reachable from the selected ref.
- `build_number`: override `CFBundleVersion` (for example to recover after an
  out-of-band upload used a higher number).
- `upload`: untick for a **dry run**. The workflow still runs `preflight`,
  signs and exports the IPA, verifies its signature and embedded profile, and
  attaches the IPA plus dSYMs as a workflow artifact, but does not talk to App
  Store Connect (no upload, no processing poll), so no build number is
  consumed. **Do this first** after adding the secrets.

Manual uploads need successful main CI on the selected source commit; a feature
branch or superseded commit cannot be published by passing a version override.
Run CI on current main first (manual CI includes Playwright). Dry-run export
remains available after native preflight without the shared upload gate.

## Build numbers

TestFlight requires `CFBundleVersion` to be unique and increasing within a
marketing version. The workflow computes

```
CFBundleVersion = BUILD_NUMBER_BASE (100) + github.run_number
```

`github.run_number` is the monotonically increasing counter of this workflow
(it never resets, including for dry runs and failed runs). The offset keeps CI
builds above the builds previously uploaded by hand (the project file is at
`CURRENT_PROJECT_VERSION = 7`). If a higher number is ever uploaded outside
CI, raise `BUILD_NUMBER_BASE` in the workflow; never lower it. The
`build_number` dispatch input overrides the computation for one run.

`manageAppVersionAndBuildNumber` is `false` in `ExportOptions.plist` so Xcode
cannot silently rewrite the value. The literal `CFBundleShortVersionString` /
`CFBundleVersion` values in `PastaIOS/PastaIOS/Info.plist` are overridden by
the `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` build settings (the target
uses `GENERATE_INFOPLIST_FILE = YES`); this was verified by inspecting the
archived `Info.plist`.

## Entitlements and capabilities

`PastaIOS/PastaIOS/PastaIOS.entitlements` requests CloudKit
(`iCloud.com.pasta.ios`, production container environment) and push
notifications (`aps-environment`, used for CloudKit change subscriptions). The
App Store profile must grant both; the workflow checks the archive carries the
`iCloud.com.pasta.ios` container and the dry run reports the `aps-environment`
value of the exported IPA (expected `production`).

## Verifying locally without secrets

The preflight suite runs locally with the same script CI uses. On a Mac that
can create simulators, `scripts/ci-ios-e2e.sh all` does everything (create and
boot a simulator, resolve, build-for-testing, test, summarise, clean up); where
`simctl create` is broken, `scripts/ci-ios-e2e.sh build-for-testing` still
compiles the app and the UI test bundle against the generic simulator
destination.

The archive step (the part that compiles the app and resolves the PastaCore /
PastaSync / PastaDetectors packages from the repo-root `Package.swift`) can be
checked on any Mac with Xcode:

```bash
xcodebuild -project PastaIOS/PastaIOS.xcodeproj -scheme PastaIOS \
  -onlyUsePackageVersionsFromResolvedFile \
  -destination 'generic/platform=iOS' -configuration Release \
  -archivePath /tmp/PastaIOS.xcarchive archive \
  CODE_SIGNING_ALLOWED=NO \
  MARKETING_VERSION=1.5.0 CURRENT_PROJECT_VERSION=101
plutil -p /tmp/PastaIOS.xcarchive/Products/Applications/PastaIOS.app/Info.plist
```

With the distribution certificate and profile installed locally, the export can
be exercised too (edit `teamID`/`provisioningProfiles` only if yours differ):

```bash
xcodebuild -exportArchive -archivePath /tmp/PastaIOS.xcarchive \
  -exportOptionsPlist PastaIOS/ExportOptions.plist -exportPath /tmp/PastaIOS-export
```

## Troubleshooting

- **"Missing required repository secret(s)"** – the first step lists exactly
  which secrets are absent. Tag pushes fail this way until all seven exist;
  nothing is uploaded.
- **"IOS_DISTRIBUTION_P12 does not contain an 'Apple Distribution' identity"**
  – the `.p12` was exported without its private key, or is a Development /
  Developer ID certificate. Re-export from *My Certificates* with the key.
- **"Profile … does not grant the iCloud.com.pasta.ios iCloud container"** –
  enable iCloud on the `com.pasta.ios` App ID, regenerate the App Store profile
  and update `IOS_APPSTORE_PROFILE`.
- **"No signing certificate 'Apple Distribution' found" / "doesn't match the
  provisioning profile"** during archive – the profile was generated for a
  different distribution certificate than the one in `IOS_DISTRIBUTION_P12`.
  Regenerate the profile selecting that certificate.
- **"The bundle version must be higher than the previously uploaded version"**
  – a build with a higher `CFBundleVersion` already exists for this marketing
  version. Re-run with a `build_number` input above it and raise
  `BUILD_NUMBER_BASE`.
- **"Authentication credentials are missing or invalid"** on upload – the API
  key was revoked, the `KEY_ID`/`ISSUER_ID` pair does not match the `.p8`, or
  the base64 secret was pasted with line breaks.
- Failed runs upload `build/archive.log`, `build/export.log` and the resolved
  `ExportOptions.plist` as the `release-ios-logs` artifact.

### Bundled iOS release notes

The TestFlight workflow runs `scripts/prepare-ios-release-notes.mjs` before
archiving, stamps the selected marketing version, build number and source SHA,
and verifies the actual archived resource before any upload. Dry-run exported
IPAs are checked as well. The SwiftPM resource
`Sources/PastaCore/Resources/IOSReleaseNotes.json` is available offline; the app
selects an exact build entry before a version-level entry and never labels a
newer or unrelated release as the installed version.

For detailed, reviewed user-facing changes, add a uniquely named JSON file to
`release-notes/ios/`, containing `summary` (a sentence) and `changes` (an array of
sentences). No next-version number is needed. The generator consumes fragments
added since the preceding release tag, so their highlights do not repeat in
later releases. Keep Mac-only work out of iOS fragments unless its effect on
shared history is explained explicitly.

Without fragments, the generator asks the existing release-note model to
summarise only iPhone/shared-library source changes. If the model is unavailable,
it reports only source-verified change areas, with the full changelog link;
it does not repeat stale highlights or invent fixes. Published GitHub releases
are backfilled as history (drafts, prereleases and failed/unpublished tags are
excluded), preserving reviewed historical prose. A missing preceding tag or an
invalid/empty catalogue fails preparation. Archive verification rejects wrong
version/build/source metadata and stale resource bytes from build caches.

An existing install sees the new sheet until it dismisses it with Done or a
swipe. First-run onboarding acknowledges the starting build. Completing the
walkthrough later must not consume pending update notes. Settings always offers
replay. The old version-only seen marker is not trusted because older builds
wrote it before their hardcoded notes were actually displayed.
