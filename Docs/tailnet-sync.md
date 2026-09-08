# Tailnet synchronisation across iCloud accounts

## Agreed product contract

Interview: 8 September 2026, Codex task 01a08307-abb1-7cb2-96a1-9d691d4ea423. Tracking: pasta-yti. Implementation, PR, review and release authorised. Specification version 1.

Pasta on personal Macs can explicitly pair across Apple accounts through an existing Tailscale installation. Each account retains its private CloudKit history. No Pasta-hosted service, Tailscale admin API key, public listener or iOS tailnet background service is required.

1. Enable Tailnet Sync (off by default), discover reachable tailnet Macs running enabled Pasta, select one and request pairing. The target displays the authenticated tailnet device name and Allow/Decline. Requests expire, are rate-limited, and do not disclose clipboard data. Both sides retain trust until removed.
2. New retained entries flow both ways; each side can explicitly send older retained history. Offline peers catch up. A failed entry must not prevent unrelated entries from syncing. Transfers are acknowledged only after durable application. Receipts survive deletion/restart so replay never resurrects deleted items.
3. Each Mac controls its outgoing sharing and forwarding. Forwarding of received items defaults off per outgoing pairing. Explicit forwarding may traverse additional pairings; stable item UUIDs prevent cycles. Tailscale device identity is independent of the Apple account.
4. Each receiving Mac controls onward iCloud upload (default off) and replacing the system clipboard (default off), independently per pairing. Clipboard writes never simulate paste and must be suppressed from capture. Backfill never replaces the system clipboard. Existing capture exclusions apply; there is no new automatic sensitive-content exclusion.
5. Content crosses a pairing once. Later edits, pins, tags, counts and deletions stay within each account. Removing a pairing stops transfers in both directions but retains received history/files under normal retention.
6. Stage one delivers pairing plus text, rich text and images. Stage two adds files/folders. Both stages are within this authorised feature and require review and native CI before publication.
7. Local file entries reference originals. At transfer, send current contents and flag a change since capture. Missing/moved originals are visibly unavailable. Never follow symbolic links outside a selected source tree. Received files go into managed storage and paste as local file URLs. No local paths/file payloads are published onward through CloudKit.
8. The sender approves file transfers above a configurable 50,000,000-byte threshold once per destination and payload version, through the transfer list (non-blocking). A selection/folder is measured in aggregate. Receiver has an independent size limit. No unapproved large payload is sent.
9. Held files are removed when their history entry is deleted or expires; explain this in settings. Never delete originals or copies saved elsewhere. Partial transfers are staged, bounded and safe to retry. Receipt, finalisation and cleanup must tolerate restart. Unpair cancels active transfers.

## Implementation design

- Keep CloudKit as its own transport. Extend local entry bookkeeping with explicit CloudKit eligibility and received provenance, preserving defaults for old databases/exports. Carry provenance in the existing CloudKit metadata field to avoid a production schema change. All upload entry points enforce eligibility.
- SQLite insertion journal gives monotonic ordering independent of device clocks, mutable copy timestamps and rowid reuse. Pairing establishes a journal baseline. Durable per-peer queues track acknowledgements, approval and failures; global receipt IDs prevent cyclic redelivery and resurrection. No content-based peer deduplication.
- macOS-only service in PastaSync uses the installed Tailscale CLI peer inventory. Bind a fixed TCP port exclusively to the local Tailscale IPv4 address; stop/rebind when identity/address changes or Tailscale disconnects. Restrict inbound callers to current visible peer IPs, and bind pairing tokens to stable Tailscale node IDs. Tailscale encrypts/authenticates the network path; application pairing adds explicit content-sharing consent and revocable random secrets in Keychain. Never treat a self-reported device name as identity.
- Bounded length-prefixed request/response protocol, explicit version, strict typed operations, no arbitrary path reads. Senders offer pending entries and push chunks to authenticated peers. Files use a validated manifest plus streamed chunks, with per-file digests and atomic staging. Constrain names, path depth, file count, total bytes, message sizes, connections and request lifetime; reject symlinks and special files rather than extracting arbitrary archives.
- Settings: enable, connection status/discovery, incoming pairing requests, paired Macs with directional policy controls, explicit send history, remove device, transfer approval/retry/status and storage explanation. Native target approval dialog also works while Settings is closed.
- Keep networking/file I/O off the main actor; only publish UI state and pasteboard changes there. Restartable service and injected transport/discovery/storage allow deterministic tests without touching personal clipboard data.

## Delivery and acceptance

1. Implement migration, policy isolation, receipt/journal/queue semantics and tests. Preserve pre-feature import/CloudKit/E2E behaviour.
2. Implement discovery, authenticated target approval, transport, scheduler, UI and clipboard suppression. Exercise two independent service instances, rejection/expiry, network loss/restart, offline catch-up, forwarding cycles, backfill, unpairing and iCloud eligibility.
3. Implement manifest/chunk file transfer, payload-bound approvals, receiver limits, source changes/unavailability, holding-area cleanup, traversal/symlink/disk/error cases and interrupted transfers.
4. Run Swift build, full parallel tests including real service E2E, release-gate script tests, bundle readiness smoke and relevant UI checks. Obtain real tailnet two-Mac evidence with synthetic payloads and separate app storage; never enable sharing of personal histories during testing.
5. Open PR with exact evidence and limitations. Wait for review, address findings, pass every required native CI gate. Use scripts/ci-merge-after-release.mjs sequentially, waiting for any earlier releases/deployments. After merge, verify main CI, macOS publication/live Sparkle signature and bundle smoke, and TestFlight VALID. Queued jobs/uploads are not completion.

## Engineering defaults and practical limits

- 50 MB uses decimal bytes and comparison is strictly greater than the threshold. Small files start automatically; declining a large transfer does not block later items. Raising a threshold does not revive an explicitly declined transfer.
- Initial peer file limit defaults to 1 GB per selection, configurable locally. Manifests cap at 10,000 entries and reject links/special files; this is a resource bound, displayed as an actionable error.
- Retention may remove source items before an offline device returns; only still-retained data can catch up. A missing original cannot be recovered from a path alone.
- Forwarding settings are automation controls, not DRM. A user can deliberately recopy content.
- New file captures preserve structured paths, including filenames containing newlines; old records retain their newline-delimited compatibility path. Rich text retains its RTF payload. Clipboard attachments are limited to 64 MB; unsupported selections surface a transfer error.
- Discovery requires an installed macOS Tailscale CLI and a tailnet IPv4 address. Offline Macs remain listed among pairings. Transfer progress/approval/retry is available in Settings → Tailnet.

## Verification record (9 September 2026)

- Full local Swift suite: 435 tests passed, including 30 tailnet-specific tests and a TCP capture-to-search-to-paste E2E. Local release-gate scripts: 27 tests passed. Landing contract tests and 12 Playwright tests passed after rebasing onto the website redesign.
- The development bundle builds, signs, launches and passes the shared readiness smoke: durable history ready, then clean SIGTERM exit. Fixed the development Run script's process check to resolve this machine's symlinked build directory.
- Rendered Settings → Tailnet inspected with native accessibility and screenshots, including off/on/connected states. Actual listener observed bound exclusively to the local tailnet IPv4 address on TCP 45873; disabling removed the listener. No pairing or personal-history sharing enabled during this UI check.
- Current Tailscale peer inventory is available, but both visible Mac peers are offline. Real two-Mac/Tailscale/Keychain/target-dialog verification remains a release gate; TCP tests substitute the tailnet inventory and credentials, so they do not establish that result.
- [PR #127](https://github.com/crmitchelmore/pasta/pull/127) is open with owner review requested. Native hosted iOS/macOS CI, independent review, and published release verification remain pending. Release requires all of them; do not infer shipment from these local results.

- Large-file preparation and final verification run in cancellable worker tasks. Tests verify that unpairing or disabling while a chunk is in flight cannot commit received history, and that reenabling resumes safely. Later source edits/pins do not overwrite previously delivered peer content. Delayed pairing replies cannot restore trust after disable/reenable; changing or removing a later peer while another peer transfers preserves the latest policy and revocation.
