# Pasta - Copilot Instructions

## Project Overview
Pasta is a macOS clipboard history manager built with SwiftUI and Swift Package Manager. It features a main app window and a Spotlight-style quick search panel.

## Architecture

### Key Components
- **PastaApp** (`Sources/PastaApp/`) - Main application, window management, hotkey handling
- **PastaCore** (`Sources/PastaCore/`) - Business logic, clipboard monitoring, database, search
- **PastaUI** (`Sources/PastaUI/`) - Reusable SwiftUI views and components
- **PastaDetectors** (`Sources/PastaDetectors/`) - Content type detection (URLs, emails, etc.)

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
**DO NOT** paste while the quick search panel is visible. The correct sequence is:

```swift
// 1. Hide the quick search panel first
quickSearchController?.hide()

// 2. Copy content to clipboard
pasteService.copy(entry)

// 3. Deactivate app to return focus to previous app
DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
    NSApp.hide(nil)
    
    // 4. Small delay then simulate Cmd+V
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        SystemPasteEventSimulator().simulateCommandV()
    }
}
```

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

### Global Hotkeys
Use the HotKey library (Carbon-based) with a fallback global NSEvent monitor:
- Carbon hotkeys work without accessibility permissions but need a proper app bundle
- Global monitor (`NSEvent.addGlobalMonitorForEvents`) requires accessibility permissions
- Both are registered for reliability

## Build & Test
```bash
swift build              # Debug build
swift build -c release   # Release build  
swift test               # Run all tests
```

## Commit Conventions
Use [Conventional Commits](https://www.conventionalcommits.org/) for all commit messages. These drive automated version bumps and releases.

### Commit types and version impact
| Prefix | Version bump | Example |
|--------|-------------|---------|
| `feat:` | Minor (0.x.0) | `feat(ui): add dark mode toggle` |
| `fix:` | Patch (0.0.x) | `fix: prevent crash on empty clipboard` |
| `perf:` | Patch (0.0.x) | `perf: reduce FTS5 query time` |
| `docs:` | No release | `docs: update README` |
| `chore:` | No release | `chore: update dependencies` |
| `ci:` | No release | `ci: add smoke test step` |
| `test:` | No release | `test: add search edge cases` |
| `refactor:` | No release | `refactor: extract paste service` |
| `style:` | No release | `style: fix indentation` |
| `build:` | No release | `build: update Package.swift` |
| `!` after type | **Major** (x.0.0) | `feat!: redesign settings API` |
| `BREAKING CHANGE:` in body | **Major** (x.0.0) | (any type with breaking body) |

### Scopes
Use optional scopes for clarity: `feat(ui):`, `fix(core):`, `perf(search):`.

## Release Process
Releases are fully automated via conventional commits:

1. Push to `main` → CI runs (build, test, smoke test)
2. CI passes → auto-release job parses commits since last tag
3. If releasable commits exist (`feat:`, `fix:`, `perf:`, or breaking) → version tag is created
4. Tag push → release workflow builds universal binary, signs, notarizes, and creates GitHub release with DMG

**No manual tagging is needed.** Just use the correct conventional commit prefix and push to main.

To force a release for non-standard commit types, use `fix:` or `feat:` prefix as appropriate.

### Protected Branch Limitation
The release workflow **cannot push to main** due to branch protection requiring status checks.

- Don't try to `git push` from release workflows to protected main branch.
- For appcast/changelog updates, deploy directly to CDN (Cloudflare Pages) without git commit.
- The appcast.xml is deployed to pasta-app.com via Cloudflare, not committed to the repo.

### Cloudflare Pages Production Deployment
When deploying to Cloudflare Pages from a tag-triggered workflow (not main branch), you MUST use `--branch=main` to deploy to production:
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
Both CI and release workflows MUST launch the signed binary and verify it stays running for 5 seconds. This is the ONLY way to catch:
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

- Feed URL: `https://pasta-app.com/appcast.xml` (deployed to Cloudflare Pages)
- The release workflow generates and uploads `appcast.xml` with EdDSA signatures
- Keys are stored in GitHub Secrets: `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY`
- UpdaterManager wraps SPUStandardUpdaterController for SwiftUI integration
- `sparkle:version` MUST match `CFBundleVersion` (build number); use `shortVersionString` for marketing version
