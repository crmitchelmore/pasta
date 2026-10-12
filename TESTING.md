# User journeys and release evidence

A green check supports only the assertions it executes. The macOS service
suite and iOS UI suite cover useful paths; neither proves a complete signed,
two-device clipboard journey. Use this map when describing release confidence.

| User journey / surface | Current evidence | Coverage boundary |
| --- | --- | --- |
| macOS copy → detect → persist → search → paste | `Tests/PastaE2ETests` runs real monitor, detector, disk database, search and paste services. | The fixture **duplicates** `BackgroundService` enrichment/insertion glue. Most pasteboard and keyboard events are doubles (the image test reads/decode-checks a real named pasteboard); it does not open the panel or inspect content received by another app. |
| macOS launch and quit | `ci-launch-smoke.sh` launches the bundle, waits for database/history/monitor readiness, and requires clean termination. Release repeats it against signed artifacts. | `PASTA_CI` suppresses CloudKit/analytics. Readiness does not prove capture, search selection, global hotkey, accessibility permission, or delivery to another app. |
| iOS install, capture, search, detail | XCUITest drives the real app/database with a controlled pasteboard. Empty history and unmatched search require exact outcomes. | Hooks seed the app-owned pasteboard. Cross-app paste permission, live iCloud, image clipboard capture and device provisioning are not exercised. |
| iOS persistence after termination | Capture → terminate → relaunch with unrelated clipboard text → search → detail proves original content survives on disk and the count is exactly two. | This proves local persistence, not transport between devices. |
| iCloud sync | Package tests exercise their stated model/persistence contracts. | Simulator UI tests disable sync. They cannot establish that two signed production clients exchange the same content, images/deletes, or recover from account/network changes. |
| Landing page | Local Playwright checks rendering, links, assets and accessibility. Contracts parse appcast and Cloudflare config. | Third-party requests are stubbed; checking an href is not completing a download. CI live probes are advisory; standalone publication now runs a required post-deploy live probe and the six-hour production monitor fails on probe errors. |
| Sparkle release | Live feed/DMG verification checks metadata, signatures, notarization and launch; failure drafts the GitHub release. | No installed older app is driven through Sparkle's update UI and relaunch. Drafting does not undo already-downloaded copies. |
| TestFlight | Processing must report `VALID`; rejection or unverified timeout fails. | Upload has already occurred. `VALID` is processing acceptance, not an installed-device journey or external tester approval. Timeout does not cancel processing. |

## Remote classification and comparison

macOS onboarding offers decision-model setup immediately after Welcome. Existing
local-only users see the optional setup once when they next open the panel.
Continue/Done or closing setup never grants upload consent; no key is mandatory.
An enabled existing provider is not migrated to remote primary mode automatically.

Settings → Detection prioritizes **Decision models**, with a preferred-provider
picker, independent credentials and modes. **Legacy classifiers (local rules)**
is collapsed by default; expanding it exposes all existing strictness, regex,
custom-detector and local-history-reparse controls without changing their values.
Local detectors remain active for privacy checks, extraction and failure fallback.
Decision models are recommended for context-aware classification, not advertised
as having a measured universal accuracy advantage.

Save a TypeSafe key with **Save and Test Key**. Saving runs a real connection
test using the harmless sample `https://example.com`; **Test Connection** repeats
it. Only a successful test of the current key, HTTPS endpoint, model and shared
rules unlocks **Allow eligible clipboard text to be sent to [provider]**.
Replacing the key or changing the endpoint/model/shared rules disables the
provider and requires another test and explicit opt-in, including after relaunch.
The defaults are `https://api.typesafe.ai/v1/systemone` and `jev-latest`.
Legacy endpoint/model settings migrate with comparison disabled.

Existing modes are preserved; installations without a saved mode remain
comparison-only at runtime until explicitly configured. Fresh setup recommends
**Use decision model by default**, but never enables it by saving/testing a key.
Only the selected preferred provider handles new captures.
**Compare only**
It sends no background captures; history is sent only after explicit confirmation.
**Use decision model by default** asynchronously applies known decisions after durable
local capture. **Use when legacy confidence is low** sends only captures with
local confidence strictly below the adjustable threshold (75% by default).
Local confidence is a detector heuristic, not a calibrated probability.
Failures and Unknown retain the local result and failures are surfaced.
Requests are serialized with a bounded live queue; overflow retains the local
result and shows an error. Authoritative modes preserve original env-var blocks;
disabled/comparison-only modes keep the legacy per-variable splitting.

**Compare Classifiers…** confirms every destination and eligible history count
before a bounded-concurrency run with progress and cancellation. Images,
file pastes, extracted children, empty entries and locally detected secrets/financial data
are skipped by default; sending sensitive types requires the separate opt-in.
Text is truncated to 20,000 characters. History comparisons run the current local
detectors afresh and do not change saved classifications. JSON/CSV reports exclude
clipboard content and keys.

**Reclassify History with [provider]…** separately confirms mutation of saved history.
Known completed decisions rebuild metadata/extracted children transactionally,
preserving original content, identity, timestamps, copy counts, pins and sharing
consent. Changed/deleted snapshots are not overwritten or resurrected. Cancellation
stops remaining work; already applied updates are retained. The final report
shows disjoint updated, retained, changed/deleted and failed counts. Changing provider,
detector, extraction or API-key exclusion settings stops application of stale decisions.
Rebuilt children obey API-key exclusion. Changed rows remain pending sync;
an older upload cannot mark a newer classification synced.
Classification writes share the macOS sync gate, so an in-flight downloaded
payload finishes before a delayed provider result can update its saved snapshot.
Retired extracted children have durable CloudKit deletion records, drained before
upload/pull and protected from delayed cloud replay, including after a restart.
Deletion acknowledgements retain retirement markers; a stale writer recreating a
retired ID queues another deletion without resurrecting the child locally.

### Microsoft Decision-1

Select **Microsoft Decision-1** in the preferred-provider picker to configure it.
It supports primary, low-legacy-confidence fallback, comparison-only and
explicit history reclassification, with its own opt-in. The [official announcement](https://commandline.microsoft.com/microsoft-decision-1-model-foundry/)
and [Foundry model card](https://ai.azure.com/catalog/models/Microsoft-Decision-1)
identify the text-only fixed-choice decision model, not MAI-Thinking-1.
Configure the **full HTTPS endpoint** as your Foundry resource endpoint followed
by `/providers/microsoft/v1/systemone`, then enter the actual **deployment name**
and its own API key. The deployment name defaults to `microsoft-decision-1`, but
must match your deployed resource. The adapter uses the `api-key` header and the
`state`/`questions`/`criteria` contract documented in
[Microsoft's Decision-1 quickstart](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision).
Resources with local/key authentication disabled cannot use this API-key adapter;
Microsoft Entra sign-in is not implemented. No shared endpoint is invented,
chat completions are not used, and the TypeSafe credential is not reused.
A successful connection test must return a served model identifying itself as
Microsoft-Decision-1 before it can be enabled.

With both providers enabled, comparison displays **local detectors, Jev and
Microsoft Decision-1 side by side**, with separate confidence, latency, model,
failure and skip information. Either provider can be compared alone. Sensitive
content consent and validation are independent per provider. A nonpreferred
provider is called only during explicitly confirmed comparison/history runs.
Switching preferred providers revokes queued live requests from the previous one,
including before transport retries and after waiting for the sync gate.
Live Microsoft connectivity still requires a
real compatible deployment and key; mock transport tests do not establish it.

### Shared decision classifier types

**Shared configuration → Shared classifier types** configures both models.
Built-in type descriptions can be edited, and up to 32 named classifiers can be
added with natural-language descriptions (no regex). Each custom label maps to
an existing nonbinary Pasta type; its name appears in the item preview and
comparison, while its mapped type controls existing filters, previews and sync.
These are not new sidebar categories and are separate from legacy regex detectors.
Definitions persist locally, use stable choice IDs, and are sent as System One
criteria. The explicit Unknown/other choice remains last. Duplicate names/IDs,
empty or oversized descriptions and unsupported mappings are rejected.
Changing shared rules disables both providers and invalidates their validation;
retest and explicitly enable each to resume. Old in-flight results cannot apply.
History mutation preserves custom names in metadata across restart/sync and removes
an old custom label when a later built-in decision replaces it.
Reports include custom label names but never original clipboard text or credentials.

### Other provider research

Official APIs reviewed for this Alpha:
[Hugging Face zero-shot classification](https://huggingface.co/docs/inference-providers/tasks/zero-shot-classification)
accepts candidate labels, but needs a different adapter and available inference
model/endpoint. [Cohere Classify](https://docs.cohere.com/v2/reference/classify)
requires at least two examples per label or a fine-tuned classifier. Neither is
System One-compatible or integrated in this Alpha. The settings links describe
these limitations rather than presenting nonfunctional provider toggles.
The implemented shared-choice contract follows
[TypeSafe Choice](https://docs.typesafe.ai/primitives/choice) and
[Microsoft's Decision-1 quickstart](https://learn.microsoft.com/en-us/azure/foundry/foundry-models/how-to/use-foundry-models-microsoft-decision).
No cloud deployment, credential or account is created by setup.

Select a comparison row to inspect its original clipboard item in the detail
pane, alongside all enabled classifications. The preview uses the local
snapshot taken for that run, so later history changes do not replace the item
you are judging. It sends no additional provider requests and remains excluded
from JSON/CSV exports. Copy is available in the preview and the row context menu.

Use **Remove Key** in the same settings section to delete the credential from
Keychain and disable comparison. A deletion error is shown rather than reported
as success. Keys are never stored in defaults; only a validation fingerprint is
persisted there. `swift test --filter 'JevClassificationTests|JevReclassificationE2ETests|JevComparisonViewTests'` covers the transport,
validation gate, retries, cancellation, report statistics and exports with a
mock API. These tests do not establish accuracy or connectivity to the live
provider; verify those with a real key and non-sensitive sample history.

## Gate failure handling

`scripts/tests/test_ci_gates.py` invokes production shell entrypoints with
controlled external tools. Success banners cannot hide an `xcodebuild` or
log-writer failure; zero/skipped/failed/malformed results cannot pass. Missing,
processing, rejected and unreachable App Store Connect builds cannot pass as
verified. These portable checks run in the required appcast contract job.

The iOS gate requires every reported test to pass without retries or skips.
It cannot prove that a test was not removed from the scheme; review changes
to test membership as carefully as assertions. An incompatible Xcode result
schema fails closed for investigation.

Landing deployment waits for completed CI, checks out that exact SHA and
independently requires macOS, iOS, appcast, path detection and Playwright
success before publishing. An automatic run with verified path detection and
a skipped browser suite makes no deployment. Manual deployment requires full
CI/browser evidence for the selected main SHA. It also rejects a SHA superseded on main, except for a verified descendant
whose only changed file is the appcast release commit-back. `ci-verify-landing-deploy.mjs` is the shared
read-only decision, exercised with failure-injection tests.

## Remaining enforcement and journey limits

Workflow gates are not repository enforcement. Read the actual GitHub rules
on main before claiming that every suite blocks merges. The owner script
requests the aggregate, macOS, iOS and appcast checks but omits the path-filtered browser job itself.
The active `Release gates` ruleset requires the always-running `CI gate` aggregate plus all three native/contract checks, scoped to GitHub Actions. The aggregate requires browser success or a verified irrelevant-path decision. Auto-release now requires
path detection itself to succeed before accepting a skipped browser suite.

The macOS release independently validates exact tagged-commit CI evidence
before GitHub publication, including manually created tags. All required
surface and path-detection jobs must have completed successfully; only a push
with successful path detection may skip Playwright. An ongoing CI run is
accepted only with these completed gates, avoiding a dependency on the
auto-release job that just created the tag. Superseded main source is checked
before GitHub publication and again before publishing the landing directory.
The iOS release retains native preflight and requires this shared exact-commit
main CI evidence immediately before every upload, including manual runs/tags.
Dry runs can still export after native preflight without publishing. Both page
publishers share a workflow-level concurrency group held through live release
verification. Failure or cancellation after publication was attempted queries
the release and drafts it if public, including when asset upload failed after
release creation. Only a 404 is harmless; API lookup/draft errors fail loudly.
The Homebrew cask update can be retried when it already matches. Portable tests
exercise partial publication recovery, API errors and a real git/tap retry. Landing deployment preserves the
fetched live feed after CI rather than publishing CI's feed bytes. Source
checks are snapshots: main can still advance after a check. Publishing GitHub,
Pages and Homebrew is not atomic, and drafting cannot undo feed/cask writes
or downloads that already happened.

The highest-value additional macOS evidence is a bundle journey that copies
unique content, opens the panel, searches/selects it, pastes into a separate
receiving app and reads back exact content. Sync needs two signed clients and
a controlled account, with persisted/displayed outcomes checked after network
failure and restart. Until then, do not describe service fixtures or readiness
smoke as full user e2e, or claim zero production regressions.

## Outstanding-issue closeout (8 September 2026)

- Local regression tests cover nonblocking/per-file image cleanup and the recent-save grace period, redacted error diagnostics, inline-image rendering and changed-byte cache invalidation.
- Quick Search `!snippet <name or keyword>` reads the current saved template at activation. Date/time, UUID, current clipboard, history offsets and cursor position are resolved for that paste. Settings CRUD/JSON round trips remain supported. Optional keyword expansion is off by default, requires Accessibility and Input Monitoring, resets on focus/pointer/navigation/secure-input changes, and retains only a bounded current token. Test with a synthetic template in a disposable receiving document before enabling it for everyday use.
- Both row renderers already share `ClipboardRowData`; detector and preview files have already been split by responsibility. The old simplification and inline-image follow-ups require verification, not a second rewrite.
- `scripts/ci-merge-after-release.mjs` refuses merges while any publication lane or main-push CI is queued/running. This preserves the strict main-supersession policy. It is a maintainer merge entrypoint, not a transactional GitHub merge queue; humans must use the same discipline. Failed completed releases permit corrective merges after investigation.
- Workflow actions are pinned to commit SHAs, Wrangler to 4.129.1, create-dmg to v1.3.0's commit, and iOS Xcode to the last green CI's 26.3. Update them with native CI evidence; do not float them during recovery.
- macOS publication retains a dSYM archive and verifies each architecture's UUID before stripping. Upload it to Sentry before claiming production symbolication. Sentry event payloads strip free-form error details, breadcrumbs, requests, user data and incidental context; stack/binary/release evidence remains. Actual event symbolication and alert routing still need a controlled event and access to the Sentry project.

See `Docs/operations-recovery.md` for recovery steps and the external evidence needed to close GitHub #110/#113. Written procedures and synthetic tests do not substitute for an observed two-device, Sparkle, or alert-delivery exercise.

`script/build_and_run.sh` builds a separate **Pasta Development** bundle with
its own defaults and (in Debug) `Pasta Development` database/image directory.
It never stops or replaces `/Applications/Pasta.app`. Quit the installed copy
before testing the shared global shortcut. The development bundle needs its
own Accessibility/Input Monitoring grants for simulated paste/keyword tests;
keep these UI checks distinct from service tests. `--build-only` stages the
bundle without launching; `--verify` checks process survival after launch.

Observed on 8 September: the installed signed app updated from 1.4.0 to 1.5.19
through Sparkle's Install and Relaunch UI, and its installed deep/strict signature
verified. A synthetic TextEdit copy/search journey then exposed the main panel
posting Cmd+V before restoring the receiver. The shared external paste coordinator
now closes the panel, activates the remembered receiver, and verifies focus
before posting keys. Re-run that journey on the newly published version.
