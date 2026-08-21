# Performance audit close-out (#51)

Status record for the launch-to-search performance audit tracked in
[#51](https://github.com/crmitchelmore/pasta/issues/51). The full evidence
(file/line citations per finding) lives in the audit plan comment on that
issue; this file records the outcome, decisions, and remaining constraints.

## Reviewer models

- Audit: **Claude Fable 5** (`claude-fable-5`), three parallel scoped review
  agents plus synthesis.
- Implementation/verification: **Claude Opus 5** (`claude-opus-5`) for the
  workstream PRs; **Claude Fable 5** for the deferred-item PRs (#61, and the
  PR closing #57). "Sol 5.6" was requested but is not an available model; a
  read-only review under that label predated the plan (see the issue's first
  comment for the availability record).

## Target budgets

| Journey point | Budget |
|---|---|
| Launch → first usable panel page (200 rows) | < 500 ms |
| Full 10k-entry background load | < 5 s, cancellation-safe |
| Quick-search open | < 100 ms |
| Search keystroke → results (10k library) | < 60 ms after last keystroke; zero main-thread DB frames |
| Selection change / preview render | < 16 ms main-thread; large-text preview < 100 ms |
| Bulk delete 1,000 entries | < 200 ms, no main-thread hang |
| Import 10–20k rows | < 10 s |
| Second consecutive "Sync Now" with no changes | 0 record uploads |
| Main-thread hangs in normal flows | none > 100 ms |

## What landed where

- **PR #53** — workstream A: search & UI responsiveness (off-main FTS,
  preview caps, debounced regex benchmarks, preload cancellation, metadata
  parse memoization, quick-search debounce fixes).
- **PR #54** — workstream B: database, lifecycle, import & sync (paged-load
  resume after insert, batched deletes, batched imports, `fetchUnsynced` for
  Sync Now, content-only FTS trigger, prune early-exits, detector input
  clamps, off-main storage settings).
- **PR #58** — `DatabaseQueue` → `DatabasePool` so reads no longer serialize
  behind writes.
- **PR #61** — clipboard capture reads moved off the main thread; image dedup
  by SHA-256 instead of retaining the last image's bytes (#56).
- **Closing #57** (this PR) — the remaining deferred items:
  - Non-initial refresh publishes the fresh first page immediately (and no
    longer strands single-page libraries with a stale list after deletes).
  - Reparse History walks the library in keyset-paged chunks with one write
    transaction per page and per-parent child rebuilds, plus a final
    orphaned-children sweep — bounded memory at any library size.
  - `FilePathDetector` caps filesystem existence checks at 20 unique
    candidates per detection pass.
  - Main-panel row models are memoized per entry version
    (`ClipboardRowModelCache`); row content length now uses `utf8.count`.
  - Main-panel image previews are cached (`NSCache`, path + pixel-size key),
    mirroring the quick-search thumbnail cache.
  - CloudKit pushes clean up their temporary `.dat` asset files once the save
    operation completes (previously leaked one per pushed record with raw
    data).
  - The `UserDefaults.didChangeNotification` handler is debounced (300 ms)
    and only restarts the monitors when the pause setting actually changed.

## Measured decision: no `entries` projection for now

The audit deferred "project the in-memory `entries` array to lighter rows"
pending measurement. Measured on 2026-08-21 (release-representative debug
build, `mach_task_basic_info` resident delta, mixed content: 80% ~120 B, 15%
~2 KB, 5% ~64 KB):

- 10,000 entries (~40 MB of content): **+47.9 MB resident, ~4.8 KB/entry**
- 50,000 entries (~208 MB of content): **+197 MB resident, ~3.9 KB/entry**

Content bytes dominate; fixed per-entry overhead is roughly 0.5–0.8 KB.
A projection would only help libraries dominated by multi-KB text entries,
at the cost of a second fetch path for every preview/filter feature.
**Decision: not implemented.** Revisit if real libraries show materially
higher per-entry cost than content size explains.

## Known constraints (accepted, documented)

- **Database migrations run on the main thread at launch.** All current
  migrations are trivial (schema DDL); if a future migration rewrites large
  tables, show an "Upgrading database…" window and run it off-main first.
  Guard rail: keep migrations O(schema), not O(rows), wherever possible.
- **Quick-search `contentLength` metadata is a UTF-8 byte count.** Identical
  to character count for ASCII; slightly larger for non-ASCII content. Chosen
  because grapheme counting is O(n) per row on the hot path.
