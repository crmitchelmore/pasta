# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->

## Build & Test

```bash
swift build                          # Debug build
swift test --parallel                # Run all tests (unit suites + PastaE2ETests)
swift test --filter PastaE2ETests    # Headless full-stack macOS e2e suite only (~2s)
swift run PastaApp                   # Launch the macOS app
```

`Tests/PastaE2ETests` drives the real service stack (fake pasteboard → `ClipboardMonitor` → detectors → on-disk `DatabaseManager` → `SearchService` → `PasteService` → row/preview rendering), plus legacy-schema migration and keyset history loads. It cannot import the `PastaApp` executable, so the glue `BackgroundService` performs is mirrored in `Tests/PastaE2ETests/E2EFixtures.swift` — keep the two in step. CI's launch smoke test runs the built bundle with `PASTA_CI=1` and waits for the `PASTA_CI_READY` marker `BackgroundService` emits once history has loaded and monitoring runs on durable storage (see `Sources/PastaApp/CIReadiness.swift`), then asserts a clean exit on SIGTERM. If the database or image storage fell back to volatile storage the app emits `PASTA_CI_DEGRADED reason=<why>` instead and `scripts/ci-launch-smoke.sh` fails immediately with that reason; `scripts/tests/test_ci_gates.py` drives the script against stand-in bundles for the ready, degraded and never-ready cases.

SwiftPM and the iOS Xcode workspace commit matching dependency locks. CI and
release commands enforce those pins; update both files together and require
native CI resolution before merging. See `Docs/dependency-reproducibility.md`
for provenance and the update procedure.

## Architecture Overview

- **PastaApp** (`Sources/PastaApp/`) — macOS executable: app delegate, floating panel, hotkeys, settings, Sparkle/Sentry wiring.
- **PastaCore** (`Sources/PastaCore/`) — platform-neutral models, GRDB database (FTS5 search), clipboard monitoring, import/export, commands.
- **PastaUI** (`Sources/PastaUI/`) — SwiftUI/AppKit views for the panel: list, search bar, previews, filters, settings tabs.
- **PastaDetectors** (`Sources/PastaDetectors/`) — content-type detectors (URLs, emails, colours, API keys, code, ...) and their strictness configuration.
- **PastaSync** (`Sources/PastaSync/`) — CloudKit sync shared by macOS and iOS; see `Sources/PastaSync/README.md`.
- **PastaIOS** (`PastaIOS/`) — Xcode project for the iOS companion app, built on PastaCore + PastaSync.

## Conventions & Patterns

- Conventional commits drive auto-release: `feat` → minor, `fix`/`perf` → patch; other types do not release.
- Privacy is opt-in only: no clipboard content ever leaves the device unless the user enables iCloud sync.
- Keep `AGENTS.md` and `CLAUDE.md` in sync — the Build/Architecture/Conventions/Release gates sections must match in both.

## Release gates

The rule is simple: **nothing reaches users unless every e2e suite on every surface is green, and what was published is re-verified from the outside.** Never add a `needs:`/`if:` bypass to these jobs; fix the red suite instead.

1. **A PR merges to `main`** only when `.github/workflows/ci.yml` is green: `test` (macOS `swift test --parallel` incl. `Tests/PastaE2ETests`, ad-hoc-signed bundle + `scripts/ci-launch-smoke.sh` readiness smoke), `ios-e2e` (XCUITests on a simulator via `scripts/ci-ios-e2e.sh`), `appcast-contract` (appcast/Cloudflare contract), and `landing-e2e` (Playwright; path-filtered, so it may be skipped). The always-running `ci-gate` job (`CI gate`) aggregates them: green only when every suite succeeded, accepting a skipped Playwright run solely when path detection proved the landing page untouched. GitHub must enforce this through a repository **ruleset** on `main` requiring a pull request plus the checks `CI gate`, `Build & Test`, `iOS E2E (XCUITest)` and `Appcast & Cloudflare config contract` (with an admin bypass so release.yml's appcast commit-back can land); it is created/updated by `scripts/owner-require-status-checks.sh`, which needs repo admin. As of 2026-09-05 that ruleset is NOT installed: `main` has no classic branch protection (GraphQL `branchProtectionRules` is empty) and its only ruleset is the Copilot-review one, so enforcement rests on convention until the owner runs the script (issue #108 / beads pasta-fyq). Never merge a PR with a red or missing gate check by hand.
2. **A macOS release is tagged** by ci.yml's `auto-release` only on a push to `main` where `ci-gate` succeeded, i.e. `test`, `ios-e2e` and `appcast-contract` succeeded and `landing-e2e` succeeded or was legitimately skipped. Any failure or cancellation means no tag, hence no release of either app. **It is published** by `.github/workflows/release.yml` only after the Developer-ID-signed, notarized, stapled DMG's contents pass `codesign --verify --deep --strict` and the same `scripts/ci-launch-smoke.sh` readiness smoke (PASTA_CI_READY marker, clean exit on SIGTERM) — this runs before "Create GitHub Release", so a failure publishes nothing.
3. **A TestFlight upload** happens in `.github/workflows/release-ios.yml` only after its `preflight` job has run the XCUITest suite (`scripts/ci-ios-e2e.sh`, identical to ci.yml's `ios-e2e`) on the ref being released. The driver requires xcodebuild exit 0 and a nonempty result bundle with every test passing and none skipped; it does not retry failures into a pass. That script's `build-for-testing` first asserts the app target's Release configuration carries the `PASTA_IOS_CLOUDKIT_PROVISIONED` compile flag (the gate `SyncManager` needs before touching CloudKit); without it a build would ship with iCloud sync silently disabled. The flag must live in the project's Release build settings — never on the `xcodebuild` command line, where it also hits SwiftPM targets and breaks GRDB. Immediately before uploading (including manual runs/tags), the shared publication gate also requires successful exact-commit main CI across every surface and rejects superseded source except appcast-only descendants. Dry runs retain native preflight but can export without this upload gate. After the upload, `scripts/ci-asc-wait-for-build.sh` polls App Store Connect (≤20 min) until the build is `VALID`; `INVALID`/`FAILED` and an unverified timeout fail the job; a timeout does not undo the upload, so inspect the existing build or rerun only the polling script.
4. **Post-publish verification** (`verify-release` in release.yml, `scripts/ci-verify-release.sh`) treats the live world as the source of truth: fetches `https://pasta-app.com/appcast.xml`, asserts the top item is the tag, that its enclosure is the just-published DMG returning HTTP 200 with a matching `Content-Length`, downloads it, mounts it, runs `stapler validate`, `spctl --assess --type execute`, `codesign --verify --deep --strict`, checks the bundle's version/build/`SUFeedURL`, verifies the enclosure's `sparkle:edSignature` is a valid Ed25519 signature of the DMG under the shipped app's `SUPublicEDKey` (`scripts/ci-verify-eddsa.sh`; a mismatch makes every installed copy silently refuse the update), and re-runs the readiness smoke on a copy. On failure it converts the GitHub release to a **draft** (Sparkle can no longer download it) and fails with a `::error::` telling you what to roll back.
5. **The appcast in git tracks the live feed.** After deploying the regenerated `appcast.xml`, release.yml commits it back to `main` (`scripts/ci-commit-appcast.sh`, `[skip ci]`, falling back to a `release/appcast-v*` branch + PR if `main` refuses the push), and ci.yml's `appcast-contract` runs with `APPCAST_REQUIRE_LATEST=1`, so a `landing-page/appcast.xml` that lags the newest **published** release fails CI instead of silently rolling Sparkle clients back on the next landing-page deploy. The reference is the newest published (non-draft) GitHub release, resolved with `gh release list` into `APPCAST_LATEST_PUBLISHED`, never the newest tag: a tag whose release failed before publication is not expected in the feed, and a feed that is *ahead* of the newest published release (release drafted or pulled) fails too. `landing-page/tests/contract/freshness.test.mjs` pins these scenarios.
7. **Production is re-probed every six hours** by `.github/workflows/monitor.yml` (`npm run test:live`): landing page and security headers, the `/download` redirect, the live appcast parsing/signature/DMG reachability, and the feed advertising the newest published release. A red scheduled run is the alert.

6. **A landing-page deployment** waits for completed CI and checks out its exact SHA. `scripts/ci-verify-landing-deploy.mjs` independently requires successful macOS, iOS, appcast, path-detection and Playwright jobs before Cloudflare publication; missing/skipped browser evidence cannot authorize a deployment. An automatic CI run with a verified irrelevant-path skip makes no deployment. Manual deployment requires successful CI/browser evidence on the selected main SHA. Before publishing, main must still match or be an appcast-only descendant (release commit-back); other superseding changes fail closed. This applies to deploy-landing-page.yml. release.yml independently applies the shared surface gate to the exact tagged commit before GitHub publication, including manually created tags; it permits a push-only browser path skip after successful path detection. Required jobs must have finished successfully even when the CI run is still completing auto-release. Both publishers reject superseded landing source before deploying and share a workflow-level concurrency group held through release verification. A failure or cancellation after GitHub publication was attempted queries the release and drafts it if public, including a partially failed asset upload; only a 404 is treated as absent. Homebrew publication is safe to retry when its cask already matches. Publication across GitHub, Pages and Homebrew is not atomic; see TESTING.md.

The shared scripts live in `scripts/ci-*.sh` and are the single source of truth — edit them, not the workflow steps. They all run locally: `scripts/ci-launch-smoke.sh <Pasta.app>`, `scripts/ci-ios-e2e.sh build-for-testing` (no simulator needed), `scripts/ci-verify-release.sh <version>` (against the live release), `scripts/ci-verify-eddsa.sh <file> <sig> <pubkey>`; `scripts/tests/ci-verify-eddsa.test.sh` round-trips the signature check and runs in the `test` job.
