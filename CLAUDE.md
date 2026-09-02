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
swift build              # Debug build
swift test --parallel    # Run all tests
swift run PastaApp       # Launch the macOS app
```

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
