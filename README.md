# 🍝 Pasta

> Your clipboard, al dente.

A blazing-fast, local-first clipboard history manager for macOS with intelligent content detection.

## Features

- **Unlimited History** — Never lose a copied item again
- **Smart Detection** — Auto-categorizes emails, JWTs, code, URLs, env vars, and more
- **Ultra-Fast Search** — Full-text search with optional fuzzy matching
- **Keyboard-First** — Global hotkey (`⌃⌘C`) and full keyboard navigation
- **Preview Everything** — Images, decoded base64, syntax-highlighted code
- **Privacy-First** — 100% local storage, no cloud sync

## Quick Start

```bash
# Build
swift build

# Run tests
swift test

# Run the app (menu bar app)
swift run PastaApp
```

## Usage

1. Copy anything (text, URLs, images, files, etc.).
2. Press **`⌃⌘C`** to show Pasta.
3. Search, navigate with **↑/↓**, then press **Enter** to paste.

> Note: Pasting via simulated **⌘V** requires Accessibility permission. Without it, Pasta will still copy the selection to your clipboard.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌃⌘C` | Show/hide Pasta |
| `↑` `↓` | Navigate history |
| `Enter` | Paste selected item |
| `1-9` | Quick-paste by position |
| `⌘⌫` | Delete selected item |
| `Esc` | Close window |

## Content Detection

Pasta automatically detects and categorizes:

| Type | Examples |
|------|----------|
| 📧 Email | user@example.com |
| 🔐 JWT | eyJhbGciOiJIUzI1NiIs... |
| 🔧 Env Var | `API_KEY=abc123` |
| 🔗 URL | https://github.com/... |
| 📁 File Path | `/Users/dev/project/` |
| 💻 Code | Swift, Python, JS, and 12+ languages |
| 📝 Prose | Natural language text |
| 🖼️ Image | Screenshots, copied images |

### Smart Features

- **Deduplication** — Identical copies tracked with count
- **Large Paste Splitting** — Multi-line env vars split into individual entries
- **Auto-Decoding** — Base64 and URL-encoded content shown decoded
- **Hot URLs** — Frequently copied URLs highlighted

## Architecture

```
Pasta/
├── Sources/
│   ├── PastaApp/        # Main app, menu bar, lifecycle
│   ├── PastaCore/       # Models, services, database
│   ├── PastaUI/         # SwiftUI views
│   └── PastaDetectors/  # Content type detection
└── Tests/
    ├── PastaCoreTests/
    └── PastaDetectorsTests/
```

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (recommended)
  - Needed for reliable global hotkey handling and for simulating paste (**⌘V**)
  - If not granted, Pasta still works as a clipboard history viewer and can copy items back to the clipboard

## Screenshots

<p align="center">
  <img src="Sources/PastaApp/Resources/Assets.xcassets/AppIcon.appiconset/icon_512x512.png" width="128" alt="Pasta app icon" />
  <img src="Sources/PastaApp/Resources/Assets.xcassets/MenuBarIcon.imageset/menubar@2x.png" width="48" alt="Pasta menu bar icon" />
</p>

## Permissions

Pasta can optionally request Accessibility access to support global shortcuts and paste simulation.

- Open **System Settings → Privacy & Security → Accessibility**
- Enable **Pasta**

If you revoke Accessibility permission, Pasta will show onboarding again and will fall back to “copy-only” paste.

## Troubleshooting

- **`⌃⌘C` hotkey does nothing**
  - Ensure Pasta is running (menu bar icon present).
  - Grant Accessibility permission (see *Permissions* above).
  - Check for hotkey conflicts in other apps.

- **Enter copies but doesn’t paste into the target app**
  - This usually means Accessibility permission is missing or was revoked.
  - Pasta will still copy the selected entry to the clipboard; you can paste manually with **⌘V**.

- **History looks empty or missing items**
  - Items copied from excluded apps won’t be recorded (see Settings).
  - If the database becomes corrupt, Pasta will attempt recovery by recreating the local DB.

- **Where is my data stored?**
  - Database: `~/Library/Application Support/Pasta/pasta.db`
  - Images: `~/Library/Application Support/Pasta/Images/`

## Development

This project uses [Ralph](https://github.com/soderlind/ralph) for AI-assisted development.

```bash
# Single iteration
./ralph-once.sh --prompt prompts/pasta.txt --prd plans/prd.json --allow-profile safe

# Multiple iterations
./ralph.sh --prompt prompts/pasta.txt --prd plans/prd.json --allow-profile safe 10
```

## Distribution

For local distribution builds, run:

```bash
./build_release.sh
```

This generates `.build/release/PastaApp.app`. To ship outside the Mac App Store, sign and notarize the app:

```bash
codesign --deep --force --options runtime --sign "Developer ID Application: YOUR NAME" ".build/release/PastaApp.app"
xcrun notarytool submit ".build/release/PastaApp.app" --wait --keychain-profile "notary"
```

### App Store vs Independent Distribution

- **App Store:** Requires sandboxing, entitlements, and App Store review. Clipboard and accessibility behaviors often need additional justification and may require changes to permission handling.
- **Independent (Developer ID):** Faster iteration and fewer restrictions. Recommended if you want full clipboard/accessibility behavior without App Store constraints.

## Storage

All data stored locally:
- Database: `~/Library/Application Support/Pasta/pasta.db`
- Images: `~/Library/Application Support/Pasta/Images/`

## License

MIT
