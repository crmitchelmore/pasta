# User journeys and release evidence

A green check supports only the assertions it executes. The macOS service
suite and iOS UI suite cover useful paths; neither proves a complete signed,
two-device clipboard journey. Use this map when describing release confidence.

| User journey / surface | Current evidence | Coverage boundary |
| --- | --- | --- |
| macOS copy → detect → persist → search → paste | `Tests/PastaE2ETests` runs real monitor, detector, disk database, search and paste services. | The fixture **duplicates** `BackgroundService` enrichment/insertion glue. Most pasteboard and keyboard events are doubles (the image test reads/decode-checks a real named pasteboard); it does not open the panel or inspect content received by another app. |
| macOS launch and quit | `ci-launch-smoke.sh` launches the bundle, waits for database/history/monitor readiness, and requires clean termination. Release repeats it against signed artifacts. | `PASTA_CI` suppresses CloudKit/analytics. Readiness does not prove capture, search selection, global hotkey, accessibility permission, or delivery to another app. |
| iOS install, capture, search, detail | XCUITest drives the real app/database with a controlled pasteboard. Empty history and unmatched search require exact outcomes. | Hooks seed the app-owned pasteboard. Cross-app paste permission, live iCloud, image clipboard capture and device provisioning are not exercised. |
| iOS persistence after termination | Capture → terminate → relaunch with unrelated clipboard text → search → detail proves original content survives on disk and the count is exactly two. | This proves local persistence, not transport between devices. |
| iCloud sync | Package tests exercise their stated model/persistence contracts. | Simulator UI tests disable sync. They cannot establish that two signed production clients exchange the same content, images/deletes, or recover from account/network changes. |
| Landing page | Local Playwright checks rendering, links, assets and accessibility. Contracts parse appcast and Cloudflare config. | Third-party requests are stubbed; checking an href is not completing a download. CI live probes are advisory; standalone publication now runs a required post-deploy live probe and the six-hour production monitor fails on probe errors. |
| Sparkle release | Live feed/DMG verification checks metadata, signatures, notarization and launch; failure drafts the GitHub release. | No installed older app is driven through Sparkle's update UI and relaunch. Drafting does not undo already-downloaded copies. |
| TestFlight | Processing must report `VALID`; rejection or unverified timeout fails. | Upload has already occurred. `VALID` is processing acceptance, not an installed-device journey or external tester approval. Timeout does not cancel processing. |

## Gate failure handling

`scripts/tests/test_ci_gates.py` invokes production shell entrypoints with
controlled external tools. Success banners cannot hide an `xcodebuild` or
log-writer failure; zero/skipped/failed/malformed results cannot pass. Missing,
processing, rejected and unreachable App Store Connect builds cannot pass as
verified. These portable checks run in the required appcast contract job.

The iOS gate requires every reported test to pass without retries or skips.
It cannot prove that a test was not removed from the scheme; review changes
to test membership as carefully as assertions. An incompatible Xcode result
schema fails closed for investigation.

Landing deployment waits for completed CI, checks out that exact SHA and
independently requires macOS, iOS, appcast, path detection and Playwright
success before publishing. An automatic run with verified path detection and
a skipped browser suite makes no deployment. Manual deployment requires full
CI/browser evidence for the selected main SHA. It also rejects a SHA superseded on main, except for a verified descendant
whose only changed file is the appcast release commit-back. `ci-verify-landing-deploy.mjs` is the shared
read-only decision, exercised with failure-injection tests.

## Remaining enforcement and journey limits

Workflow gates are not repository enforcement. Read the actual GitHub rules
on main before claiming that every suite blocks merges. The owner script
requests the aggregate, macOS, iOS and appcast checks but omits the path-filtered browser job itself.
The active `Release gates` ruleset requires the always-running `CI gate` aggregate plus all three native/contract checks, scoped to GitHub Actions. The aggregate requires browser success or a verified irrelevant-path decision. Auto-release now requires
path detection itself to succeed before accepting a skipped browser suite.

The macOS release independently validates exact tagged-commit CI evidence
before GitHub publication, including manually created tags. All required
surface and path-detection jobs must have completed successfully; only a push
with successful path detection may skip Playwright. An ongoing CI run is
accepted only with these completed gates, avoiding a dependency on the
auto-release job that just created the tag. Superseded main source is checked
before GitHub publication and again before publishing the landing directory.
The iOS release retains native preflight and requires this shared exact-commit
main CI evidence immediately before every upload, including manual runs/tags.
Dry runs can still export after native preflight without publishing. Both page
publishers share a workflow-level concurrency group held through live release
verification. Failure or cancellation after publication was attempted queries
the release and drafts it if public, including when asset upload failed after
release creation. Only a 404 is harmless; API lookup/draft errors fail loudly.
The Homebrew cask update can be retried when it already matches. Portable tests
exercise partial publication recovery, API errors and a real git/tap retry. Landing deployment preserves the
fetched live feed after CI rather than publishing CI's feed bytes. Source
checks are snapshots: main can still advance after a check. Publishing GitHub,
Pages and Homebrew is not atomic, and drafting cannot undo feed/cask writes
or downloads that already happened.

The highest-value additional macOS evidence is a bundle journey that copies
unique content, opens the panel, searches/selects it, pastes into a separate
receiving app and reads back exact content. Sync needs two signed clients and
a controlled account, with persisted/displayed outcomes checked after network
failure and restart. Until then, do not describe service fixtures or readiness
smoke as full user e2e, or claim zero production regressions.

## Outstanding-issue closeout (8 September 2026)

- Local regression tests cover nonblocking/per-file image cleanup and the recent-save grace period, redacted error diagnostics, inline-image rendering and changed-byte cache invalidation.
- Quick Search `!snippet <name or keyword>` reads the current saved template at activation. Date/time, UUID, current clipboard, history offsets and cursor position are resolved for that paste. Settings CRUD/JSON round trips remain supported. Optional keyword expansion is off by default, requires Accessibility and Input Monitoring, resets on focus/pointer/navigation/secure-input changes, and retains only a bounded current token. Test with a synthetic template in a disposable receiving document before enabling it for everyday use.
- Both row renderers already share `ClipboardRowData`; detector and preview files have already been split by responsibility. The old simplification and inline-image follow-ups require verification, not a second rewrite.
- `scripts/ci-merge-after-release.mjs` refuses merges while any publication lane or main-push CI is queued/running. This preserves the strict main-supersession policy. It is a maintainer merge entrypoint, not a transactional GitHub merge queue; humans must use the same discipline. Failed completed releases permit corrective merges after investigation.
- Workflow actions are pinned to commit SHAs, Wrangler to 4.129.1, create-dmg to v1.3.0's commit, and iOS Xcode to the last green CI's 26.3. Update them with native CI evidence; do not float them during recovery.
- macOS publication retains a dSYM archive and verifies each architecture's UUID before stripping. Upload it to Sentry before claiming production symbolication. Sentry event payloads strip free-form error details, breadcrumbs, requests, user data and incidental context; stack/binary/release evidence remains. Actual event symbolication and alert routing still need a controlled event and access to the Sentry project.

See `Docs/operations-recovery.md` for recovery steps and the external evidence needed to close GitHub #110/#113. Written procedures and synthetic tests do not substitute for an observed two-device, Sparkle, or alert-delivery exercise.

`script/build_and_run.sh` builds a separate **Pasta Development** bundle with
its own defaults and (in Debug) `Pasta Development` database/image directory.
It never stops or replaces `/Applications/Pasta.app`. Quit the installed copy
before testing the shared global shortcut. The development bundle needs its
own Accessibility/Input Monitoring grants for simulated paste/keyword tests;
keep these UI checks distinct from service tests. `--build-only` stages the
bundle without launching; `--verify` checks process survival after launch.

Observed on 8 September: the installed signed app updated from 1.4.0 to 1.5.19
through Sparkle's Install and Relaunch UI, and its installed deep/strict signature
verified. A synthetic TextEdit copy/search journey then exposed the main panel
posting Cmd+V before restoring the receiver. The shared external paste coordinator
now closes the panel, activates the remembered receiver, and verifies focus
before posting keys. Re-run that journey on the newly published version.
