# Correctness Bugs Implementation Notes

Temporary reconciliation note for `planning/audit/01-correctness-bugs.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- C-1: Replaced the lossy feed mapping with RSS 2.0 and Atom parsing that preserves content, summaries, authors, timestamps, categories, enclosures, and raw parsed metadata.
  - Added realistic rich RSS and Atom fixtures plus parser tests.
- C-2: Added durable multi-key article aliases and group-scoped stable-ID dedupe.
  - A migration backfills every existing primary key; advisory transaction locks and unique aliases make concurrent convergence deterministic.
- C-3: Replaced hand-built XML and CDATA interpolation with Saxy XML construction.
  - Direct controller tests cover delimiter escaping and well-formed output.
- C-4: Feed collection now records item-level ingestion/processing failures and finishes the parent run instead of crashing the entire fetch.
- C-5: Raw-item and article creation now converge under database conflicts and concurrent processing.
  - Concurrency regression coverage exercises raw item, article, source appearance, and generated-item convergence.
- C-6: Advancing an item no longer rewrites completed step history.
- C-7: Representative re-election preserves extraction-corrected article metadata.
- C-8: Dashboard article totals include the valid `skipped` state.
- C-9: Production port publication follows the configured Phoenix `PORT`.
- C-10: Generated-feed memberships are preserved when membership keys are absent and cleared only by explicit empty values.

## Not Implemented

- None.

## Auditor Notes

- Verify the parser against the included rich fixtures and the direct FeedController suite.
- Verify the article dedupe-key migration and concurrent intake test together; they are one correctness change.
- Focused Elixir tests for these paths passed before full-suite reconciliation.
