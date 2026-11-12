# Pasta - Copilot Instructions

`AGENTS.md` at the repository root is the source of truth for build and test commands, architecture, release gates and merge rules. This file adds code patterns and signing notes; where the two differ, follow `AGENTS.md`.

## Project Overview
Pasta is a macOS clipboard history manager built with SwiftUI and Swift Package Manager, with an iOS companion app (`PastaIOS/`) and opt-in iCloud and Tailnet sync. The Mac app has a main window and a Spotlight-style quick search panel.

## Architecture

### Key Components
- **PastaApp** (`Sources/PastaApp/`) - Main application, window management, hotkey handling
- **PastaCore** (`Sources/PastaCore/`) - Business logic, clipboard monitoring, database, search
- **PastaUI** (`Sources/PastaUI/`) - Reusable SwiftUI views and components
- **PastaDetectors** (`Sources/PastaDetectors/`) - Content type detection (URLs, emails, etc.)
- **PastaSync** (`Sources/PastaSync/`) - CloudKit sync and macOS tailnet pairing; see `Sources/PastaSync/README.md`
- **PastaIOS** (`PastaIOS/`) - Xcode project for the iOS companion app

### Window Types
- **MainWindow** - Standard resizable window for browsing clipboard history
- **QuickSearchWindow** - Floating panel (NSPanel) for quick Spotlight-style search

## Critical Patterns

### Search Implementation (FTS5)
**ALWAYS** use SQLite FTS5 for search, not in-memory fuzzy search libraries.

The database has an FTS5 virtual table (`clipboard_entries_fts`) with triggers to keep it synced.
Use `DatabaseManager.searchFTS()` which supports prefix matching:

```swift
// Fast: FTS5 search (<1ms for 10k+ entries)
let results = try database.searchFTS(query: "hello", contentType: nil, limit: 50)

// The query "hello world" becomes FTS5 query "hello* world*" for prefix matching
```

**Why:** In-memory Fuse search caused 200-500ms delays and beach ball on 6k+ entries.
FTS5 runs in SQLite's optimized C engine with inverted index.

**Also:** When filtering results on main thread, limit input to ~200 entries max:
```swift
let limited = Array(input.prefix(200))  // Prevent main thread blocking
```

### Quick Search Paste Behavior
**DO NOT** paste while the quick search panel is visible. Route pastes into other apps through `ExternalPasteCoordinator.shared.paste(...)` (`Sources/PastaApp/ExternalPasteCoordinator.swift`) rather than sequencing it by hand. It copies the entry, hides the panel and the app, reactivates the remembered previous app, and sends Cmd+V via `SystemPasteEventSimulator` only once that app is frontmost again.

**Why**: If you paste while the panel is visible, Cmd+V goes to our app instead of the user's previous app.

### Search Performance in SwiftUI
**NEVER** use computed properties for search results in SwiftUI views. This causes:
- Multiple recalculations per render (each access triggers search)
- Main thread blocking during typing
- Laggy/frozen UI

**DO** use this pattern:
```swift
// State for results
@State private var displayedEntries: [ClipboardEntry] = []
@State private var searchDebounceTask: Task<Void, Never>? = nil

// Debounced search trigger
.onChange(of: searchQuery) { _, newQuery in
    searchDebounceTask?.cancel()
    let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    
    if trimmed.isEmpty {
        displayedEntries = allEntries  // Immediate for empty
    } else {
        searchDebounceTask = Task {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms debounce
            guard !Task.isCancelled else { return }
            
            // Run search OFF main thread
            let results = await Task.detached(priority: .userInitiated) {
                // search logic here
            }.value
            
            await MainActor.run { displayedEntries = results }
        }
    }
}
```

### Sidebar / Filters Performance (SwiftUI)
Avoid O(N) work inside SwiftUI `View` computed properties (e.g. sidebar counts).
If counts/derived data depend on `entries`, precompute once when entries change
(`.onReceive(backgroundService.$entries)` or similar), store in `@State`, and pass into views.

For large datasets (5k+), also preload first-page results per filter (e.g. per ContentType)
off-main-thread so switching filters is instant.

### Initial History Load Performance
For large clipboard histories, preserve perceived launch speed:
- Publish a small first page immediately (currently 200 recent entries), then load the remaining history in bounded background pages.
- Show lightweight loading/progress feedback in the main window while history is still loading.
- Avoid duplicate startup refreshes between app launch and main-panel appearance.

### Source App Identity
When displaying or filtering source apps, canonicalise source identifiers before grouping:
- Treat bundle identifiers and display names for the same installed app as one identity.
- Keep every raw alias behind that identity so selecting a single sidebar row filters all matching entries.
- Use one shared resolver for app display names and icons across the sidebar, list rows, preview headers, and Quick Search, with fallbacks for imported names and Continuity.

### Copy Affordances Across Content Surfaces
When adding copy affordances for clipboard entries, cover both the list row and the preview/content pane. Users expect easy copying from the full content view as well as from each item in the list.

### Pathological Metadata Resilience
When entries contain large detector metadata (hundreds/thousands of matches), preserve interactivity first:
- Never do unbounded metadata parsing/rendering on the main thread.
- Cap inline detected-item rendering (start at 100) and use progressive disclosure ("Show more").
- If metadata payload is oversized, show a lightweight summary/fallback instead of pretty-printing full JSON.
- Keep the reparse action in Settings → Detection so users can rerun historical reclassification after rule changes.

### Detector Rules Customisation Contract
- Detector matching behaviour is user-configurable runtime state, not compile-time constants.
- Use `DetectorConfigurationStore` as the source of truth (global strictness, per-detector overrides, advanced regex, custom detectors).
- Any new built-in detector must be added to `BuiltInDetectorKind` defaults and surfaced in Settings → Detection.
- Reparse/history rebuild flows must apply the active detector configuration so rule changes can clean existing data.
- Advanced regex paths must preserve compile validation and performance-rating feedback before save.

### Performance Regression Verification
For reported hangs/freezes, verify with evidence before marking fixed:
1. Reproduce against the user-provided pathological sample (or equivalent real payload).
2. Confirm no main-thread stall in the affected interaction path (e.g. filter click + item selection).
3. Run `swift build && swift test` after the fix and report both reproduction result and test/build status.

### Keyboard Event Handling in SwiftUI
SwiftUI's `.onKeyPress` doesn't work when a TextField has focus. Use `NSEvent.addLocalMonitorForEvents`:

```swift
localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
    // Return nil to consume the event, return event to pass through
    return handleKeyEvent(event) ? nil : event
}
```

**Important**: Only intercept specific keys (arrows, Return, Escape, Cmd+1-9). Return the event unchanged for all other keys so TextField typing works.

### NSViewRepresentable Content Updates
When wrapping SwiftUI content in NSViewRepresentable, the content must be updated in `updateNSView`:

```swift
func updateNSView(_ nsView: KeyInterceptingView, context: Context) {
    nsView.updateContent(content)  // Must update hosted content!
}

// In NSView subclass:
private var hostingView: NSHostingController<AnyView>?

func updateContent<Content: View>(_ content: Content) {
    hostingView?.rootView = AnyView(content)
}
```

### Database Migrations — Backfill Rule
When adding a new column that tracks state (e.g. `isSynced`, `isArchived`), always add a
follow-up migration that backfills existing rows based on current system state. New columns
default to their initial value, which may be incorrect for pre-existing data.

```swift
// BAD: only adds column, existing entries all get isSynced = false
migrator.registerMigration("addIsSynced") { db in
    try db.alter(table: "clipboard_entries") { t in
        t.add(column: "isSynced", .boolean).notNull().defaults(to: false)
    }
}

// GOOD: adds column THEN backfills based on known state
migrator.registerMigration("backfillIsSynced") { db in
    try db.execute(sql: "UPDATE clipboard_entries SET isSynced = 1 WHERE isSynced = 0")
}
```

### Persisting User-Visible State
Any state shown in the UI that should survive app restart MUST be persisted:
- Counts/statistics → derive from database queries, not in-memory counters
- Timestamps (e.g. "Last Synced") → persist to UserDefaults
- Never use `@Published var` as the sole store for data the user expects to see on relaunch

### Global Hotkeys
The quick search hotkey uses Carbon `RegisterEventHotKey` through `CarbonHotKeyManager` (`Sources/PastaUI/CarbonHotKeyManager.swift`), configured by the user as a `PastaHotKey` and registered in `Sources/PastaApp/AppDelegate/AppDelegate+HotKey.swift`:
- Carbon hotkeys work without accessibility permissions but need a proper app bundle
- Global monitors (`NSEvent.addGlobalMonitorForEvents`, used by snippet expansion) require accessibility permissions

### Settings Window Width Guardrail
When adding new tabs to `SettingsView`, increase the fixed settings window width so tabs remain visible and do not collapse into the macOS "Navigation Tab Bar" overflow popout.
Keep `SettingsView.Layout.settingsWidth` updated whenever tab count/labels change.

## Build & Test
```bash
swift build              # Debug build
swift build -c release   # Release build
swift test --parallel    # Run all tests (unit suites + PastaE2ETests)
```

See `AGENTS.md` for the e2e suite, launch smoke test and the CI jobs a PR must pass.

### Detector Regression Checks
When changing detector rules or metadata extraction:
1. Reproduce with a long-number/blob sample and verify medium strictness suppresses noisy phone matches.
2. Verify lax/strict profile behaviour and advanced regex capture-group overrides.
3. Run targeted detector tests (`PhoneNumberDetectorTests`, strictness config tests) before full `swift build && swift test`.

## Commit Conventions
Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages. The commit type decides the release-note section (`scripts/release-notes-lib.mjs`); it does not choose version numbers or trigger a release.

| Prefix | Release-note section | Example |
|--------|----------------------|---------|
| `feat:` | New and improved | `feat(ui): add dark mode toggle` |
| `fix:` | Fixes | `fix: prevent crash on empty clipboard` |
| `perf:` | Performance | `perf: reduce FTS5 query time` |
| `refactor:`, `build:`, `ci:`, `test:`, `chore:` | Under the hood | `chore: update dependencies` |
| `docs:` | Documentation | `docs: update README` |
| anything else | Other changes | |

### Scopes
Use optional scopes for clarity: `feat(ui):`, `fix(core):`, `perf(search):`.

## Release Process
Releases use Alpha and Stable trains (`Docs/release-trains.md`; gates in `AGENTS.md`):

1. Every successful main CI push is eligible for Alpha; `alpha-release.yml` builds and publishes it as a GitHub prerelease with its own Sparkle feed.
2. Stable is promoted explicitly: **Prepare Stable** (`prepare-stable.yml`) freezes a verified Alpha with chosen macOS and iOS marketing versions, then the owner approves **Publish Stable** (`publish-stable.yml`).
3. Manual legacy tags do not publish.

### Release Notes Quality
- Release notes must include a compare link, grouped conventional-commit sections, commit links, and key touched files.
- Avoid placeholder changelog text (for example, "See commit history"); include concrete shipped changes.

### Release Completion Reporting
- When asked to confirm release completion, wait until the latest CI run on `main` and the resulting Alpha or Publish Stable runs, including their live verification, have succeeded (no queued/in-progress runs).
- Report released tag(s) and release URL(s) as evidence.

### Appcast Commit-Back
After deploying `appcast.xml`, the release workflow commits it back to `main` as `landing-page/appcast.xml` (`scripts/ci-commit-appcast.sh`, through the `Release gates` ruleset's admin bypass, falling back to a PR). CI fails if the committed appcast lags the newest published release. See release gate 5 in `AGENTS.md`.

### Cloudflare Pages Production Deployment
When deploying to Cloudflare Pages from a workflow, pass `--branch=main` to deploy to production, as `deploy-landing-page.yml` and `publish-stable.yml` do:
```bash
wrangler pages deploy landing-page --project-name=pasta-app --branch=main
```
Without `--branch=main`, deployments go to preview URLs only.

## SPM + Dynamic Frameworks (Sparkle)

When using Swift Package Manager with dynamic frameworks like Sparkle, the release workflow must:

1. **Copy the framework** to `Contents/Frameworks/`:
```bash
SPARKLE_PATH=$(find .build -name "Sparkle.framework" -type d | head -1)
cp -R "$SPARKLE_PATH" "$APP_DIR/Contents/Frameworks/"
```

2. **Fix the rpath** so the binary can find it:
```bash
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP_DIR/Contents/MacOS/PastaApp"
```

**Why**: SPM sets `@loader_path` as rpath, but frameworks are in `Contents/Frameworks/`. Without the rpath fix, the app crashes on launch with `Library not loaded: @rpath/Sparkle.framework`.

**CI Smoke Test**: The CI workflow creates a test app bundle and verifies it can launch. This catches framework bundling issues before release.

## Code Signing — Critical Rules

These rules exist because we shipped **four broken releases** (v0.8.0–v0.9.2) that crashed on launch. `codesign --verify` and `spctl --assess` both PASS for all of these issues — only actually launching the binary catches them.

### Rule 1: NEVER apply app entitlements to framework binaries
```bash
# WRONG — this will crash at launch with "code signature invalid"
find "$APP_DIR" -type f -perm +111 | while read binary; do
  codesign --entitlements entitlements.plist "$binary"  # ← DO NOT DO THIS
done

# CORRECT — sign frameworks WITHOUT entitlements, only main binary gets them
# 1. Sign framework internals (no entitlements)
find "$APP_DIR/Contents/Frameworks" -type f -perm +111 | while read binary; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$binary"
done
# 2. Sign main binary WITH entitlements
codesign --force --sign "$IDENTITY" --options runtime --timestamp \
  --entitlements entitlements.plist "$APP_DIR/Contents/MacOS/PastaApp"
```

**Why**: dyld rejects frameworks that have restricted entitlements (iCloud, CloudKit, etc.) they weren't provisioned for. The error is `Library not loaded: code signature invalid`.

### Rule 2: NEVER add restricted entitlements without updating the provisioning profile
These entitlements require matching capabilities in the provisioning profile:
- `aps-environment` — requires Push Notification capability
- `com.apple.developer.icloud-services` — requires iCloud capability
- `com.apple.developer.icloud-container-identifiers` — requires iCloud capability
- `com.apple.application-identifier` — must match profile's application-identifier

If a restricted entitlement is in the binary but not in the provisioning profile, **AMFI kills the app with SIGKILL on launch**. There is NO error message — the app just silently dies.

### Rule 3: CloudKit requires `com.apple.application-identifier`
Xcode adds this automatically, but manual `codesign` does not. Without it, CloudKit fails at runtime with `CKError 8 "Missing Entitlement"`. Format: `TeamID.BundleID` (e.g. `8X4ZN58TYH.com.pasta.clipboard`).

### Rule 4: ALWAYS launch-test the signed binary
Both CI (every main push, and PRs routed to the full lane) and release workflows MUST launch the signed bundle with `scripts/ci-launch-smoke.sh`, which waits for the app's `PASTA_CI_READY` marker and then requires a clean exit on SIGTERM. This is the ONLY way to catch:
- AMFI SIGKILL from restricted entitlements
- dyld crashes from framework signing issues
- Missing framework bundles

`codesign --verify` and `spctl --assess` do NOT catch these issues.

### Rule 5: CI smoke test uses ad-hoc signing with stripped entitlements
CI has no Developer ID cert or provisioning profile. The CI smoke test:
1. Strips restricted entitlements (iCloud, aps-environment) using plistlib
2. Signs with ad-hoc identity (`--sign -`)
3. Launches with `PASTA_CI=1` to disable CloudKit init

The release workflow has its own separate launch test using the real Developer ID signature.

### Entitlements source of truth
All entitlements live in `Resources/release.entitlements` (committed). Both CI and release workflows reference this file. Never inline entitlements in workflow YAML.

### Debugging "The application can't be opened"
1. Check `log show` for `AMFI`, `code signature error`, `ASP: Security policy`
2. Check crash reports in `~/Library/Logs/DiagnosticReports/`
3. Run the binary directly: `/Applications/Pasta.app/Contents/MacOS/PastaApp`
4. Check entitlements: `codesign --display --entitlements - /Applications/Pasta.app/Contents/MacOS/PastaApp`
5. Check framework entitlements are clean: `codesign -d --entitlements - .../Sparkle.framework/Versions/B/Sparkle`

## Sparkle Auto-Updates

- Feed URL: `https://pasta-app.com/appcast.xml` (deployed to Cloudflare Pages); Alpha uses its own feed at `https://pasta-app.com/alpha/appcast.xml`
- The release workflow generates and uploads `appcast.xml` with EdDSA signatures
- Keys are stored in GitHub Secrets: `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY`
- UpdaterManager wraps SPUStandardUpdaterController for SwiftUI integration
- `sparkle:version` MUST match `CFBundleVersion` (build number); use `shortVersionString` for marketing version

## Sentry Error Tracking

- **Organisation slug**: `tally-lz`
- **Project slug**: `pasta`
- **API token env var**: `$SENTRY_AUTH_TOKEN` (set in `~/.zshrc`)
- **API base**: `https://sentry.io/api/0/projects/tally-lz/pasta/`
- **DSN**: configured in `Sources/PastaApp/SentryManager.swift`
- **Useful endpoints**:
  - List unresolved issues: `curl -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "https://sentry.io/api/0/projects/tally-lz/pasta/issues/?query=is:unresolved&sort=freq"`
  - Get latest event for issue: `curl -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "https://sentry.io/api/0/issues/{issue_id}/events/latest/"`
  - Get issue details: `curl -H "Authorization: Bearer $SENTRY_AUTH_TOKEN" "https://sentry.io/api/0/issues/{issue_id}/"`
