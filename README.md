# 🍝 Pasta

> Your clipboard, al dente.

A blazing-fast, local-first clipboard history manager for macOS with intelligent content detection.

## Features

- **Unlimited History** — Never lose a copied item again
- **Smart Detection** — Auto-categorizes emails, JWTs, code, URLs, env vars, and more
- **Detection Rules** — Tune detector strictness, override regex patterns, and add custom detectors
- **Ultra-Fast Search** — Full-text search with fuzzy matching
- **Keyboard-First** — Global hotkey (`⌃⌘V`) and full keyboard navigation
- **Preview Everything** — Images, decoded base64, syntax-highlighted code
- **Privacy-First** — 100% local storage, no cloud sync

## Installation

### Homebrew (Recommended)

```bash
brew tap crmitchelmore/pasta
brew install --cask pasta
```

### Download

Download the latest DMG from [Releases](https://github.com/crmitchelmore/pasta/releases).

### Build from Source

```bash
git clone https://github.com/crmitchelmore/pasta.git
cd pasta
swift build -c release
swift run PastaApp
```

## Usage

1. Copy anything (text, URLs, images, files, etc.).
2. Press **`⌃⌘V`** to show Pasta.
3. Search, navigate with **↑/↓**, then press **Enter** to paste.

> Note: Pasting via simulated **⌘V** requires Accessibility permission.

## Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| `⌃⌘V` | Show/hide Pasta |
| `↑` `↓` | Navigate history |
| `Enter` | Paste selected item |
| `⌘1-9` | Quick-paste by position |
| `⌘⌫` | Delete selected item |
| `Esc` | Close window |

## Content Detection

| Type | Examples |
|------|----------|
| 📧 Email | user@example.com |
| 🔐 JWT | eyJhbGciOiJIUzI1NiIs... |
| 🔧 Env Var | `API_KEY=abc123` |
| 🔗 URL | https://github.com/... |
| 📁 File Path | `/Users/dev/project/` |
| 💻 Code | Swift, Python, JS, and more |
| 🖼️ Image | Screenshots, copied images |

Detection behaviour is configurable in **Settings → Detection** with:
- Global and per-detector strictness profiles (`Lax`, `Medium`, `Strict`)
- Advanced regex overrides with performance ratings (`Fast`, `Reasonable`, `Slow`)
- User-defined custom detectors for domain-specific patterns

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (recommended for paste simulation)

## Data Storage

All data stored locally:
- Database: `~/Library/Application Support/Pasta/pasta.sqlite`
- Images: `~/Library/Application Support/Pasta/Images/`

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## Support

Pasta is free and open source. If you find it useful, consider supporting development:

- 💝 [GitHub Sponsors](https://github.com/sponsors/crmitchelmore)
- ☕️ [Ko-fi](https://ko-fi.com/crmitchelmore)
- ⭐️ Star this repo!

## License

MIT
