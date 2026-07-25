# Minor Issues Implementation Notes

Temporary reconciliation note for `planning/audit/08-minor-issues.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- N-1: Added `dc:creator`, Atom self metadata, channel homepage behavior, optional publication dates, and structured category/enclosure output.
- N-3: Escaped literal `%`, `_`, and escape characters in article search.
- N-4: Feed ingestion batches per-row events and emits a single intake update.
- N-5: Separated programmatic feed-fetch state and raw-item ownership fields from public changesets.
- N-6: Enforced singleton settings in Postgres and made default creation conflict-safe.
- N-8: Expired site backoffs no longer appear active solely because an old counter remains.
- N-9: Added a direct output-feed enable/disable action that preserves memberships.
- N-11/N-12: Digestion truncates once and fingerprints exactly the content visible to the model.
- N-13: Command workers accept structured argv lists safely.
- N-14: Added a configurable dev Postgres port, production app healthcheck, `tini`, and deploy health waiting.
- N-15: Removed duplicate feed loading and moved rendering-dependency validation into the domain update path.
- N-17: Automatic retry origin and bounded attempt number are persisted and visible in Processing.

## Not Implemented

- N-2: Publisher-specific parameter stripping and HTTP/HTTPS or `www` equivalence remain a product correctness decision in `planning/open-questions.md`.
- N-7: Second-granularity pacing drift is intentionally accepted at current multi-second site intervals.
- N-10: The hosted read route intentionally exists only for extracted content.
- N-14 database URL derivation: rejected because `DATABASE_URL` is the project's explicit dev/prod portability contract. Production now requires it instead.
- N-16: Current producers use integer related IDs; defensive legacy parsing remains at the boundary.

## Auditor Notes

- N-1 is covered by direct well-formed RSS tests.
- N-2 should be decided from observed duplicate URLs, not a broad normalization rule that could merge distinct publisher resources.
