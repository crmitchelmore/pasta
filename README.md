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

# Run the app
swift run PastaApp
```

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
- Accessibility permission (for global hotkey)

## Development

This project uses [Ralph](https://github.com/soderlind/ralph) for AI-assisted development.

```bash
# Single iteration
./ralph-once.sh --prompt prompts/pasta.txt --prd plans/prd.json --allow-profile safe

# Multiple iterations
./ralph.sh --prompt prompts/pasta.txt --prd plans/prd.json --allow-profile safe 10
```

## Storage

All data stored locally:
- Database: `~/Library/Application Support/Pasta/pasta.db`
- Images: `~/Library/Application Support/Pasta/Images/`

## License

MIT
