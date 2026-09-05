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
| Landing page | Local Playwright checks rendering, links, assets and accessibility. Contracts parse appcast and Cloudflare config. | Third-party requests are stubbed; checking an href is not completing a download. Live probes remain advisory. |
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
requests macOS, iOS and appcast checks but omits the path-filtered browser job.
An always-running aggregate required check could require either browser
success or a verified irrelevant-path decision. Auto-release now requires
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
