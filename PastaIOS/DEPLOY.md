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

See [Alpha and Stable release trains](../Docs/release-trains.md) for the current
workflow. Every successful main merge is eligible for a separate Alpha app;
Stable requires an explicitly approved candidate with cumulative release notes.
The reusable iOS worker retains native XCUITest preflight, archive identity and
Production CloudKit verification, exact-source CI and App Store processing checks.
Existing Apple builds are reused on retries. Upload is not public availability.


## Build numbers

The immutable train manifest owns version/build values. Each train allocates an
increasing ordinal; iOS uses `1000 + ordinal` and direct Mac preserves its existing
timestamp ordering. Never upload outside this allocator without first reserving a
higher build. Failed/invalid uploads require a new attempt, not a reused number.
`manageAppVersionAndBuildNumber` remains false so Xcode cannot rewrite the manifest.

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

The manifest freezes deterministic notes and their hash before packaging. Alpha
notes describe that source change; Stable notes accumulate since the last observed
published iOS release. The worker embeds the exact version/build/source catalogue,
and archive verification rejects stale or mismatched resources. History is capped
at 40 entries in the same train. See [release trains](../Docs/release-trains.md).
