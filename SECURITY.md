# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 0.1.x   | :white_check_mark: |

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
   - Send details to: [your-email@example.com]
   - Use PGP encryption if available (key: [link to public key])

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

- ✅ **100% local storage** - No cloud sync, no data leaves your machine
- ✅ **No network requests** - App doesn't connect to the internet
- ✅ **SQLite encryption** - Database can be encrypted at rest (future feature)
- ✅ **Sandboxed permissions** - Only requests necessary macOS permissions

### Data Storage

Clipboard data is stored locally at:
- Database: `~/Library/Application Support/Pasta/pasta.db`
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

For non-security issues, please use [GitHub Issues](https://github.com/yourusername/pasta/issues).

For security concerns, use the reporting methods above.

---

**Thank you for helping keep Pasta secure!** 🍝🔒
