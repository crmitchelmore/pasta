# Semantic search

Semantic search finds history items by what they *mean*, not just the words
they contain. It is off by default and lives in **Settings → Search**.

Example: an Apple Watch serial number such as `F4GXK2J1HG7Q`, copied from an
iPhone via Continuity, has no words in common with the query
`apple watch serial number`. Keyword search cannot find it; semantic search
can.

## How it works

1. **Enriched documents.** Each primary entry is embedded as a short
   description plus its content, e.g.
   `Text. Code of 12 uppercase letters and digits; could be a serial number,
   product key, … Copied from another Apple device (iPhone, iPad or Mac) via
   Continuity.` followed by the text itself. The description comes from the
   detected type, the *shape* of short opaque tokens (codes, long numbers,
   grouped keys, PIN-like numbers) and the source app. This is what lets
   opaque identifiers match descriptive queries.
2. **Embeddings provider.** Pasta sends documents to an OpenAI-format
   `/embeddings` endpoint:
   - **OpenAI** — `text-embedding-3-small`, reduced to 512 dimensions.
   - **Azure OpenAI** — the v1 endpoint
     (`https://<resource>.openai.azure.com/openai/v1/embeddings`), with the
     deployment name as the model and the key sent as `api-key`.
   - **OpenAI-compatible** — any local server (Ollama, LM Studio, …) on a
     loopback address, e.g. `http://localhost:11434/v1/embeddings` with
     `nomic-embed-text`. Nothing leaves the Mac.
   Keys are stored in the device-only login Keychain. The feature can only be
   switched on after **Save and Test** succeeds for the exact provider,
   endpoint, model and key. A successful test does not turn it on; nothing is
   indexed until you switch on **Search by meaning**. Plain HTTP is accepted
   only for `localhost` or a literal loopback address (127.0.0.0/8, `::1`).
3. **Index.** Vectors are stored in the `semantic_embeddings` table, keyed by
   entry and an *index key* (provider, endpoint URL, model, dimensions,
   document version). Changing the key rebuilds the index; changing an
   entry's text, type, detections, source app or sharing settings re-checks
   and re-embeds that entry. Indexing runs in
   the background, newest first, in batches of 32, and pauses on errors
   (configuration errors wait for a settings change; others retry after a
   minute).
4. **Search.** Queries of three or more characters are embedded after typing
   settles (350 ms) and compared against an in-memory matrix with Accelerate
   (about a millisecond for 10k entries). Only hits that stand out from the
   rest of the history are kept: the cut-off is relative to the score
   distribution, because absolute cosine scores differ between models.
5. **Hybrid ranking.** Semantic hits are merged with FTS5 keyword results using
   reciprocal rank fusion, in both the main window and Quick Search. Keyword
   results appear immediately; meaning-based matches join them a moment later.
   Entries that literally contain the query always stay on top, and active
   filters apply to both lists.

## Privacy

With a remote provider (OpenAI or Azure), Pasta never sends:

- entries detected as secrets or financial data (API keys, JWTs, env vars,
  payment cards, IBANs, …), including entries that merely *contain* one;
- entries kept off iCloud, entries received over Tailnet Sync, and file paths;
- images and screenshots.

Those entries are recorded as *skipped* and are still found by keyword search.
A local loopback server indexes everything except images, since the text never
leaves the Mac. Query text is sent to the provider each time a semantic search
runs. Turning the feature off stops all requests; stored vectors stay on disk
until **Rebuild Index** or a provider change.

## Possible follow-ups

- A bundled on-device model (e.g. a Core ML export of bge-small), so semantic
  search works with no provider. Apple's built-in `NLEmbedding` models ranked
  poorly in prototypes.
- "Related" badges on rows that were found by meaning only
  (`QuickSearchManager.semanticMatchIDs` already exposes them).
- Query/document prefixes for models that expect them (e.g. nomic's
  `search_query:`).
