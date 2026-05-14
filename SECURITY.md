# Security Policy

## Supported Versions

The latest 1.x release is supported. Older 0.x preview releases are no longer
maintained — please update to 1.x to receive security fixes.

| Version | Supported          |
| ------- | ------------------ |
| 1.x     | :white_check_mark: |
| 0.x     | :x:                |

## Reporting a Vulnerability

We take the security of Pasta seriously. If you discover a security vulnerability, please follow these steps:

### How to Report

**Please DO NOT open a public issue for security vulnerabilities.**

Instead, report security issues via one of these methods:

1. **GitHub Security Advisories** (Preferred)
   - Go to the repository's Security tab
   - Click "Report a vulnerability"
   - Fill out the advisory form

2. **Email** (Alternative)
   - Send details to: chrismitchelmore@gmail.com
   - Mark the subject line `[Pasta Security]` so it bypasses filters.

### What to Include

Please provide:

- **Description** of the vulnerability
- **Steps to reproduce** the issue
- **Potential impact** (what can an attacker do?)
- **Suggested fix** (if you have one)
- **Your contact information** for follow-up

### What to Expect

- **Acknowledgment:** We'll confirm receipt within 48 hours
- **Updates:** We'll keep you informed of our progress
- **Timeline:** We aim to release a fix within 90 days for valid issues
- **Credit:** We'll acknowledge your contribution in the security advisory (unless you prefer anonymity)

## Security Considerations

### Local-First Design

Pasta is designed with privacy and security in mind:

- ✅ **Local-first storage** - Clipboard contents are stored on-device by default.
- ✅ **No telemetry by default** - Crash reporting (Sentry) is **off** until you opt in via Settings → General → Diagnostics. No clipboard contents are ever included in crash reports.
- ✅ **Optional iCloud sync** - CloudKit sync is opt-in and uses your private iCloud database. Disable it in Settings → iCloud if you prefer purely local storage.
- ✅ **Auto-updates via Sparkle** - Pasta checks for updates from the project's signed appcast. You can disable automatic checks in Settings → About.
- ✅ **Sandboxed permissions** - Only requests necessary macOS permissions.

### Data Storage

Clipboard data is stored locally at:
- Database: `~/Library/Application Support/Pasta/pasta.sqlite`
- Images: `~/Library/Application Support/Pasta/Images/`

**Security Note:** This data is **not encrypted** by default. Ensure your macOS user account is protected with:
- FileVault disk encryption (recommended)
- Strong user password
- Automatic screen lock

### Permissions

Pasta requests these macOS permissions:

1. **Accessibility** (optional but recommended)
   - Used for: Global hotkey detection and simulating paste (Cmd+V)
   - Security: Cannot access content outside the app without user action
   
2. **Clipboard Access**
   - Used for: Monitoring clipboard for new items
   - Security: Only reads, never modifies clipboard without user action

### Sensitive Data

**Warning:** Pasta records **all** clipboard content by default, which may include:
- Passwords (if copied)
- API keys and tokens
- Private messages
- Sensitive documents

**Recommendations:**
1. Use the **app exclusion list** to prevent recording from password managers (e.g., 1Password, Bitwarden)
2. Manually **delete sensitive entries** after use (Cmd+Backspace)
3. Use **"Delete last X minutes"** feature to clear recent sensitive copies
4. Never sync `~/Library/Application Support/Pasta/` to cloud storage

## Known Security Limitations

1. **No encryption at rest** - Database and images stored in plaintext (mitigated by macOS FileVault)
2. **Simulated keystrokes** - Paste feature uses CGEvent API (requires Accessibility permission)
3. **No clipboard sanitization** - Malicious content (e.g., Unicode exploits) is stored as-is
4. **App exclusion bypass** - Determined users can still copy-paste from excluded apps via indirect methods

## Best Practices for Users

- ✅ Enable **FileVault** disk encryption on your Mac
- ✅ Exclude password managers from clipboard monitoring
- ✅ Regularly delete old clipboard history
- ✅ Don't copy credentials; use password manager auto-fill instead
- ✅ Keep macOS and Pasta updated to the latest version

## Security Updates

Security patches will be released as:
- **Critical:** Immediate patch release
- **High:** Patch within 7 days
- **Medium:** Included in next scheduled release
- **Low:** Addressed in future versions

## Scope

**In scope:**
- Unauthorized access to clipboard data
- Privilege escalation attacks
- Memory corruption or crashes from malicious clipboard content
- Database injection or corruption
- Accessibility API abuse

**Out of scope:**
- Social engineering attacks
- Physical access to unlocked Mac
- Issues in third-party dependencies (report to upstream)
- Feature requests or non-security bugs (use GitHub Issues)

## Past Security Advisories

None yet (project is new).

## Contact

For non-security issues, please use [GitHub Issues](https://github.com/crmitchelmore/pasta/issues).

For security concerns, use the reporting methods above.

---

**Thank you for helping keep Pasta secure!** 🍝🔒
