# Alpha and Stable releases

Pasta Alpha for Mac installs alongside Pasta with a separate bundle ID, preferences,
history, CloudKit container and Tailnet pairing credentials/port. It has no global
shortcut until one is explicitly chosen. Stable retains its existing identity and data.

On iOS there is one app: Pasta (`com.pasta.ios`, one App Store Connect record).
Alpha builds are TestFlight builds of that app, distributed only to its TestFlight
beta groups, so App Review never sees a second bundle ID for the same app
(Guideline 4.3(a)). An iOS Alpha replaces the App Store install, shares its data
and syncs through the Production `iCloud.com.pasta.ios` container. The older
"Pasta Alpha" record (`com.pasta.ios.alpha`) is no longer used; automation never
deletes or modifies it.

The supported distribution surfaces are the existing direct macOS/Sparkle app and
iOS TestFlight/App Store app. This does not add a macOS App Store target.

Every successful main CI push is eligible for Alpha. `alpha-release.yml` queues
immutable `alpha-build-N` manifests; an hourly reconciliation catches interrupted
runs. Automatic allocation was enabled in `Config/ReleasePipeline.json` on
12 September 2026 so that Alpha builds reach the Sparkle feed
(`https://pasta-app.com/alpha/appcast.xml` answers 503 "Alpha is not available
yet" until the first `alpha-latest` pointer exists). Enabling is not delivery
evidence: signed archives, device coexistence and an installed N to N+1 Sparkle
update must still be recorded from real runs. The owner can also commission a
specific successful main source manually.
Each Alpha surface is built independently: the direct Mac app runs first and
the iOS lane queues behind it on the shared runner, so a slow or failing TestFlight
upload never delays the Alpha Sparkle feed. A retry (`release-train.mjs plan`)
rebuilds only the surfaces whose receipts are not yet delivered; a verified Mac
build interrupted before publication only reruns the idempotent `publish-alpha`.
A failed upload keeps its receipt and build number; retries reuse an existing
Apple build, while an invalid binary requires a new allocation (dispatch Alpha
with `rebuild`). The owner can retry just the iOS lane with **Release iOS
(TestFlight)** and the manifest tag.
Reconciliation only retries the newest successful main source and only submits
the newest Alpha for TestFlight beta review; superseded sources are never
rebuilt with current workflows. An iOS receipt still processing or awaiting
beta review counts as delivered: the hourly Apple reconciler advances it, so the
Alpha workflow is not redispatched while Apple reviews. Before submission the Pasta app's Beta App
Review contact is filled from App Store Connect (its Test Information, else its App
Store review contact); no contact data is committed.

TestFlight groups on the Pasta app (names are fixed in `scripts/release-apple.rb`):

- **Internal Alpha** (internal testers): each Alpha is added as soon as it is
  `VALID`. Keep automatic distribution off, otherwise Stable candidates would
  reach it too.
- **Public Alpha** (external, public link): each newest Alpha is submitted for
  Beta App Review and added once approved.

What to Test for every Alpha starts with "Pasta Alpha build N (tag).
Pre-release: not the App Store version." Alpha builds are never submitted for
App Store review.

Alpha is a GitHub prerelease, never GitHub Latest. Only the README advertises
`/alpha/download` and the Public Alpha TestFlight group. The Alpha Sparkle feed
resolves one monotonic pointer to immutable assets. Website downloads, Homebrew,
the existing Sparkle feed and App Store remain Stable.

## Stable promotion

1. Run **Prepare Stable** on main with a verified Alpha tag and explicit macOS and
   iOS marketing versions. Only the Alpha direct Mac receipt must be verified;
   an iOS Alpha that is still in Apple review does not block a Sparkle release.
2. Review the candidate's frozen manifest and complete cumulative notes. Each
   surface starts from its last published Stable source, not its latest upload,
   rejected review or Alpha build. Paired reverts cancel and platform-specific
   changes stay on their surface. The tested source and dependency lock are frozen.
3. Candidate workers rebuild that source using Stable identities and stage signed,
   verified assets and processed App Store candidates. The Mac candidate builds
   first; the iOS candidate follows and its receipt is not required to publish. Stable builds are never
   assigned to TestFlight groups; only Alpha builds go to Internal Alpha and Public Alpha.
   Validate Stable archives and runtime separately before owner approval.
4. Run **Publish Stable** with the candidate tag and the exact reviewed manifest
   SHA-256. Only the repository owner may approve. Changed notes/assets or a newer
   candidate for the same version invalidate publication.
5. Direct publication updates GitHub Latest, the Stable feed and Homebrew, then
   downloads and verifies the live signed DMG. Publication gates only on the
   direct Mac surface. App Store submission is asynchronous: `release-apple.rb
   submit-if-ready` runs best-effort after publication and again from the hourly
   Apple reconciler for the newest owner-approved candidate. It submits only once
   the owner approval is recorded, the matching direct release is public and the
   Stable build is `VALID`, using `AFTER_APPROVAL`. Apple rejections are reported
   as warnings and never resubmitted automatically. Processing, submission and
   public availability have separate receipts; reconciliation advances Apple's
   notes boundary only after observed public availability. Alpha can continue
   while Apple reviews Stable. If an earlier Stable version still occupies
   Apple's review or release slot, the next approved candidate reports pending
   without changing that submission; reconciliation resumes after Apple releases
   the slot.

No Stable candidate is approved merely by merging this implementation.

## Signing and CloudKit

Stable signing secrets remain unchanged. iOS Alpha signs with the Stable
`IOS_APPSTORE_PROFILE`; Mac Alpha uses `ALPHA_MACOS_PROVISIONING_PROFILE`, both with
existing distribution certificates. `ALPHA_IOS_APPSTORE_PROFILE` is no longer read.
Archive validation requires the exact train bundle, source, version/build, notes
hash, Sparkle feed and per-surface Production CloudKit container.

Alpha and Stable iOS builds share one record, so the allocator reads both
trains' tags: iOS `CFBundleVersion` is one counter, above every earlier iOS build
of either train. An iOS Alpha's marketing version is the configured
`versions.ios` or, when higher, a patch above the newest Stable candidate
(Stable 1.10.0 gives Alpha 1.10.1), because Apple refuses builds for a released
version. The direct-Mac build and both trains' ordinals stay per train.

### Direct macOS package size

Alpha and Stable retain universal ARM/Intel executables and identical features.
Each release also ships thin `-AppleSilicon.dmg` and `-Intel.dmg` builds, made
by `lipo -thin` on every Mach-O of the universal app and then signed,
notarised and launch-tested like the universal DMG. The Intel DMG launches under
Rosetta; on a runner without Rosetta it gets the static checks and a warning. They are about half the size. The
website's `/download` routes and the Homebrew cask serve them, falling back to
the universal DMG for releases without them. Sparkle keeps the universal DMG:
clients before Sparkle 2.9 cannot filter enclosures by hardware, and an update
replaces the installed app whatever chip built it.
`ci-prepare-macos-executable.sh` captures and verifies matching dSYMs before
stripping the main executable's nonessential symbol table, retaining imports
and dynamically referenced exports. Matching UUIDs are checked again afterward;
the separate dSYM archive remains available for crash symbolication.

`ci-stage-macos-resources.py` stages SwiftPM resource bundles once, including
release notes, train configuration and dependency privacy manifests. Source icon
catalogs are excluded from the executable target; they remain in the repository
for full-resolution ICNS generation. Installed packages keep only the selected
train's full-resolution ICNS; the SwiftPM development PNG fallbacks, both
trains' source artwork and duplicate loose resource copies are not shipped. CI
launch-tests the same resource staging and stripping path as releases.

`ci-create-macos-dmg.sh` uses lossless LZMA (`ULMO`) compression, supported since
macOS 10.15, below Pasta's macOS 14 minimum. The volume icon is the train ICNS
without its 1024 px slot (`ci-slim-icns.py`). Releases ship the committed,
pre-optimised ICNS and DMG background (`Resources/Branding/README.md`) rather
than regenerating them. The Finder window layout (background, icon positions,
window size) is a committed `.DS_Store` per volume name in
`Resources/DMG/Layout/`, copied into the volume with create-dmg's
`--skip-jenkins`, so release runners never script Finder (it timed out with
AppleEvent -1712 on the headless runner). After changing the layout constants
in `ci-create-macos-dmg.sh`, the background or a train `displayName`, run
`bash scripts/generate-dmg-layout.sh` on a logged-in Mac with create-dmg
installed and commit the regenerated templates; `test_macos_packaging.py`
fails when a train has no matching template. Signing,
notarisation, Sparkle signatures and pre-/post-publication verification remain
unchanged. Optimisations happen before signing; never modify a signed bundle or
recompress an already Sparkle-signed update.

Pasta Alpha iOS: `com.pasta.ios` with `iCloud.com.pasta.ios` (the Stable app).
Direct Mac Alpha: `com.pasta.clipboard.alpha` with `iCloud.com.pasta.ios.alpha`, so
iOS Alpha syncs with Stable Mac, not Mac Alpha. On 9 September 2026 the Alpha
container's Production schema
was deployed and matched the Stable Production schema byte-for-byte (SHA-256
`b4e159c6e3fbbc89d96827af78d49b064508c80fc5182179fe176aff49ef3a88`).
Only schema definitions were copied. No Stable user data was migrated.

## Validation and recovery

Native macOS/iOS E2E, appcast contract and applicable browser CI remain mandatory
for the exact commit. They always run on main after merge, while PRs get the fast
gate (see `AGENTS.md`, Release gates), so a red main never allocates an Alpha.
Release archives also run signing, notarisation, launch and external download
checks. GitHub, Pages and Homebrew publication is not atomic: if post-publication
verification fails, the release is drafted and the failed workflow identifies the
need to restore the previous verified feed/cask. Inspect existing receipts before
retrying; never upload a duplicate Apple build or retarget an immutable tag.
Apple processing polls require exactly one matching bundle identifier, even
when the API returns Alpha alongside Stable. A missing or ambiguous identity
fails explicitly instead of polling the first app returned. After an upload
timeout, the Apple reconciler can verify the existing build and persist its
receipt without repeating the upload.

Run `node --test scripts/tests/*.test.mjs`,
`ruby scripts/tests/release_apple_test.rb`, the Python gate suite, `swift test
--parallel`, and the landing-page contract/browser suites. A local pass is not a
substitute for hosted native CI or physical-device delivery evidence.
