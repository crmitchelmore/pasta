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
- ✅ **No telemetry by default** - Both telemetry features are **off** until you opt in via Settings → General → Diagnostics, and neither ever includes clipboard contents:
  - **Crash reporting (Sentry)** - Crash reports and minimal performance traces. Requires an app restart to take effect.
  - **Product analytics (PostHog, EU region)** - Applies immediately, no restart. Pasta posts a single
    JSON body to `https://eu.i.posthog.com/capture`; no vendor SDK is linked, so there is no
    autocapture, session replay, remote config, or error capture.
    - **Sent:** the event name (`app_active_daily`, `analytics_opt_in`, `analytics_opt_out`,
      `paste_performed`, `search_performed`, `settings_opened`), a bounded property per event
      (`content_type` from Pasta's detected-type enum; `has_filter` true/false), the app version and
      build, the macOS major.minor version, the distribution channel, the ISO 639 language subtag
      (region dropped — `en-GB` and `en-US` both report `en`), the CPU architecture, and a random
      UUID generated on your Mac at opt-in.
    - **Never sent:** clipboard contents, search query text, source app names, file paths, URLs,
      window titles, location data, your name, email, account or device identifiers. Every property
      is an enum raw value or a boolean — there is no code path that can attach a free-form string.
    - **IP address:** like any HTTPS request, the upload carries your IP to the server. Pasta puts
      no location or network data in the payload and never stores your IP itself, but what the
      receiving PostHog project does with it is a server-side setting, not something the app can
      enforce. **Maintainer note:** GeoIP enrichment and IP storage must be disabled in the PostHog
      project settings; the "no IP stored" guarantee holds only while they are off.
    - **Withdrawal:** turning the toggle off sends one final `analytics_opt_out` event, then deletes
      the random UUID and the on-disk queue of any events that had not yet been delivered.
    - **Unconfigured builds:** if a build has no PostHog project key (all local and self-built
      binaries), analytics are a permanent no-op that opens no files and makes no requests.
- ✅ **Optional iCloud sync** - CloudKit sync is opt-in and uses your private iCloud database. Disable it in Settings → iCloud if you prefer purely local storage.
- ✅ **Auto-updates via Sparkle** - Pasta checks for updates from the project's signed appcast. You can disable automatic checks in Settings → About.
- ✅ **Sandboxed permissions** - Only requests necessary macOS permissions.

### Data Storage

Clipboard data is stored locally at:
- Database: `~/Library/Application Support/Pasta/pasta.sqlite`
- Images: `~/Library/Application Support/Pasta/Images/`
- Analytics state (only when opted in): `~/Library/Application Support/Pasta/analytics_state.json`
  (consent flag, random UUID, last daily-event date) and `analytics_queue.json` (undelivered
  events, pruned to 7 days / 1000 entries). Both are deleted when you opt out.

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
