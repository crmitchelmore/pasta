# Release and service recovery

Keep the working published release as the reference. Failed tags are not
promotions. Never rewrite an update feed to match a failed/unpublished tag.

## Merge and publication order

Use `scripts/ci-merge-after-release.mjs <PR> --check` after review, then the same
command without `--check` to merge. The script checks required PR statuses and
all active publication lanes, including queued runners, and checks main again
before merging the expected PR head. It never uses an admin bypass. Wait for
macOS publication and its external verifier, TestFlight `VALID`, landing
publication, and the live appcast commit-back before the next merge. This
applies to docs/build commits as well: commit prefixes cannot establish that a
superseding change is safe. The repository admin exception exists for release
appcast commit-back; do not use it to bypass code review or checks.

Completed failed releases need diagnosis, but do not permanently lock out a
corrective PR. For a failed upload, query App Store Connect for the existing
version/build and rerun only `ci-asc-wait-for-build.sh`; never duplicate an
upload just because polling timed out.

## Signing keys and symbols

1. Identify the failed identity/profile from metadata, without printing keys.
   Validate expiry, team, bundle ID and iCloud/APS entitlements against
   `PastaIOS/DEPLOY.md` and the release lane.
2. Restore the existing certificate and its private key from the owner's
   encrypted backup into an isolated keychain. A certificate without its
   private key cannot sign. Keep the current valid identity until its
   replacement has passed a dry run. Never revoke working keys pre-emptively.
3. Run the native iOS preflight and dry-run export. For macOS, verify the
   Developer ID signature, notarization, staple and launch readiness on the
   exported DMG using the existing release verifier. Do not rotate Sparkle's
   Ed25519 key: installed clients trust the key embedded in their old bundle.
4. Retain the matching `PastaApp.dSYM.zip` published with the macOS release.
   `ci-verify-symbols.py` must match every binary architecture. Upload those
   symbols in the Sentry project's debug-files page; verify a controlled crash
   resolves the application's frames and its release/build before declaring
   symbolication working.

Evidence still needed: owner-confirmed backup location and a successful
isolated restore/export exercise. Do not store private keys in issues/artifacts.

## CDN and feed recovery

1. Read the latest published GitHub release, the live feed, `/download`, and
   the failing monitor output. Distinguish unavailable DNS/CDN from bad content.
2. Run `npm run test:live` in `landing-page`. It fails if the published release
   reference cannot be obtained; a stale/unpublished tag is never a substitute.
3. Redeploy the CI-verified current main through `Deploy Landing Page`, which
   preserves the live feed and re-probes after deployment. If the feed itself
   is corrupt, recover it from the verified latest release's asset and use the
   release recovery process; do not blindly deploy a stale checkout.
4. If a release verifier drafts a bad release, inspect any feed/cask state
   left by partial publication. Restore only a verified still-public version,
   then rerun `ci-verify-release.sh <version>` and the production monitor.

Evidence: the exact deployment SHA, successful post-publication probe, latest
published tag and live feed version. A passing local page build is insufficient.

## CloudKit recovery and signed journeys

Use two signed clients on the same owner-approved test iCloud account, with
synthetic text and generated images. Record app versions/builds, never real
clipboard content or account credentials. Verify each stage independently:

- Copy a unique synthetic value on client A, observe durable history, refresh
  B, search/select/paste into a disposable receiver, and read back the value.
- Repeat with generated images; compare decoded pixels, then replace bytes on
  the same record ID and ensure the preview and pasted pixels change.
- Delete, restart both clients and prove the record stays deleted.
- Disconnect/reconnect networking, change test accounts, and exercise an expired
  token using test fixtures. Confirm persisted pending state is retried and the
  token advances only after changes have been applied.

Do not delete production CloudKit zones or reset a user's history to simulate
failure. `SyncAccountRecoveryTests` and `SyncPullServiceTests` cover synthetic
state transitions; they cannot establish live two-client transport.

For macOS also exercise denied/restored Accessibility in a disposable test
profile, global hotkey/search/selection, text/image paste and restart. For
Sparkle, install an older signed bundle in a disposable profile, update via its
normal UI, relaunch and inspect the installed version. Mounting the new DMG is
not proof of an installed update.

## Monitoring and Sentry evidence

The production monitor runs every six hours; GitHub workflow notifications are
the configured alert mechanism. Its workflow owner must confirm receipt of a
controlled failure notification. Keep synthetic failure tests in a test branch
or staging environment; do not break production just to test alerting.

Sentry remains opt-in. Use a controlled test event after consent in a test
profile, inspect its raw payload for synthetic sentinel leakage, confirm stack
symbolication against the retained dSYM UUIDs, and confirm alert delivery to the
project's configured recipient. Project access and recipient confirmation are
required external evidence; neither a configured DSN nor SDK startup proves it.
