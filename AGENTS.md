# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

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
- Keep `AGENTS.md` and `CLAUDE.md` in sync — the Build/Architecture/Conventions sections must match in both.
