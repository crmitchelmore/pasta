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

## Release Process
Push a version tag to trigger the release workflow:
```bash
git tag v0.x.x && git push origin v0.x.x
```

The workflow builds a universal binary, signs, notarizes, and creates a GitHub release with DMG.

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
