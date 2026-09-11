# Alpha and Stable releases

Pasta Alpha installs alongside Pasta with separate bundle IDs, preferences, history,
CloudKit container and Tailnet pairing credentials/port. It has no global shortcut
until one is explicitly chosen. Stable retains its existing identity and data.

The supported distribution surfaces are the existing direct macOS/Sparkle app and
iOS TestFlight/App Store app. This does not add a macOS App Store target.

Every successful main CI push is eligible for Alpha. `alpha-release.yml` queues
immutable `alpha-build-N` manifests; an hourly reconciliation catches interrupted
runs. `Config/ReleasePipeline.json` keeps automatic commissioning disabled until
signed archives, device coexistence and update delivery have been verified. The
owner can commission a specific successful main source manually during setup.
A failed upload keeps its receipt and build number; retries reuse an existing
Apple build, while an invalid binary requires a new allocation.

Alpha is a GitHub prerelease, never GitHub Latest. Only the README advertises
`/alpha/download` and the Public Alpha TestFlight group. The Alpha Sparkle feed
resolves one monotonic pointer to immutable assets. Website downloads, Homebrew,
the existing Sparkle feed and App Store remain Stable.

## Stable promotion

1. Run **Prepare Stable** on main with a verified Alpha tag and explicit macOS and
   iOS marketing versions. Both Alpha surface receipts must be verified.
2. Review the candidate's frozen manifest and complete cumulative notes. Each
   surface starts from its last published Stable source, not its latest upload,
   rejected review or Alpha build. Paired reverts cancel and platform-specific
   changes stay on their surface. The tested source and dependency lock are frozen.
3. Candidate workers rebuild that source using Stable identities and stage signed,
   verified assets and processed App Store candidates. Stable builds are never
   assigned to TestFlight groups; Alpha alone uses its Public Alpha group.
   Validate Stable archives and runtime separately before owner approval.
4. Run **Publish Stable** with the candidate tag and the exact reviewed manifest
   SHA-256. Only the repository owner may approve. Changed notes/assets or a newer
   candidate for the same version invalidate publication.
5. Direct publication updates GitHub Latest, the Stable feed and Homebrew, then
   downloads and verifies the live signed DMG. Apple submission uses the selected
   build and `AFTER_APPROVAL`. Processing, submission and public availability have
   separate receipts; reconciliation advances Apple's notes boundary only after
   observed public availability. Alpha can continue while Apple reviews Stable.

No Stable candidate is approved merely by merging this implementation.

## Signing and CloudKit

Stable signing secrets remain unchanged. Alpha uses `ALPHA_IOS_APPSTORE_PROFILE`
and `ALPHA_MACOS_PROVISIONING_PROFILE` with existing distribution certificates.
Archive validation requires the exact train bundle, source, version/build, notes
hash, Sparkle feed and isolated Production CloudKit container.

Pasta Alpha iOS: `com.pasta.ios.alpha`; direct Mac: `com.pasta.clipboard.alpha`.
Both use `iCloud.com.pasta.ios.alpha`. On 9 September 2026 its Production schema
was deployed and matched the Stable Production schema byte-for-byte (SHA-256
`b4e159c6e3fbbc89d96827af78d49b064508c80fc5182179fe176aff49ef3a88`).
Only schema definitions were copied. No Stable user data was migrated.

## Validation and recovery

Native macOS/iOS E2E, appcast contract and applicable browser CI remain mandatory.
Release archives also run signing, notarisation, launch and external download
checks. GitHub, Pages and Homebrew publication is not atomic: if post-publication
verification fails, the release is drafted and the failed workflow identifies the
need to restore the previous verified feed/cask. Inspect existing receipts before
retrying; never upload a duplicate Apple build or retarget an immutable tag.

Run `node --test scripts/tests/*.test.mjs`,
`ruby scripts/tests/release_apple_test.rb`, the Python gate suite, `swift test
--parallel`, and the landing-page contract/browser suites. A local pass is not a
substitute for hosted native CI or physical-device delivery evidence.
