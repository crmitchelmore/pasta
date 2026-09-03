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

`Tests/PastaE2ETests` drives the real service stack (fake pasteboard → `ClipboardMonitor` → detectors → on-disk `DatabaseManager` → `SearchService` → `PasteService` → row/preview rendering), plus legacy-schema migration and keyset history loads. It cannot import the `PastaApp` executable, so the glue `BackgroundService` performs is mirrored in `Tests/PastaE2ETests/E2EFixtures.swift` — keep the two in step. CI's launch smoke test runs the built bundle with `PASTA_CI=1` and waits for the `PASTA_CI_READY` marker `BackgroundService` emits (see `Sources/PastaApp/CIReadiness.swift`), then asserts a clean exit on SIGTERM.

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

1. **A PR merges to `main`** only when `.github/workflows/ci.yml` is green: `test` (macOS `swift test --parallel` incl. `Tests/PastaE2ETests`, ad-hoc-signed bundle + `scripts/ci-launch-smoke.sh` readiness smoke), `ios-e2e` (XCUITests on a simulator via `scripts/ci-ios-e2e.sh`), `appcast-contract` (appcast/Cloudflare contract), and `landing-e2e` (Playwright; path-filtered, so it may be skipped).
2. **A macOS release is tagged** by ci.yml's `auto-release` only on a push to `main` where `test`, `ios-e2e` and `appcast-contract` succeeded and `landing-e2e` succeeded or was skipped. Any failure or cancellation means no tag, hence no release of either app. **It is published** by `.github/workflows/release.yml` only after the Developer-ID-signed, notarized, stapled DMG's contents pass `codesign --verify --deep --strict` and the same `scripts/ci-launch-smoke.sh` readiness smoke (PASTA_CI_READY marker, clean exit on SIGTERM) — this runs before "Create GitHub Release", so a failure publishes nothing.
3. **A TestFlight upload** happens in `.github/workflows/release-ios.yml` only after its `preflight` job has run the XCUITest suite (`scripts/ci-ios-e2e.sh`, identical to ci.yml's `ios-e2e`) on the ref being released. After the upload, `scripts/ci-asc-wait-for-build.sh` polls App Store Connect (≤20 min) until the build is `VALID`; `INVALID`/`FAILED` fails the job, a timeout only warns.
4. **Post-publish verification** (`verify-release` in release.yml, `scripts/ci-verify-release.sh`) treats the live world as the source of truth: fetches `https://pasta-app.com/appcast.xml`, asserts the top item is the tag, that its enclosure is the just-published DMG returning HTTP 200 with a matching `Content-Length`, downloads it, mounts it, runs `stapler validate`, `spctl --assess --type execute`, `codesign --verify --deep --strict`, checks the bundle's version/build/`SUFeedURL`, and re-runs the readiness smoke on a copy. On failure it converts the GitHub release to a **draft** (Sparkle can no longer download it) and fails with a `::error::` telling you what to roll back.

The shared scripts live in `scripts/ci-*.sh` and are the single source of truth — edit them, not the workflow steps. They all run locally: `scripts/ci-launch-smoke.sh <Pasta.app>`, `scripts/ci-ios-e2e.sh build-for-testing` (no simulator needed), `scripts/ci-verify-release.sh <version>` (against the live release).
