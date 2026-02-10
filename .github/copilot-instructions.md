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

## Sparkle Auto-Updates

- Feed URL: `https://github.com/crmitchelmore/pasta/releases/latest/download/appcast.xml`
- The release workflow generates and uploads `appcast.xml` with EdDSA signatures
- Keys are stored in GitHub Secrets: `SPARKLE_PUBLIC_KEY`, `SPARKLE_PRIVATE_KEY`
- UpdaterManager wraps SPUStandardUpdaterController for SwiftUI integration
