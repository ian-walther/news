# Dead Code And Schema Cruft Implementation Notes

Temporary reconciliation note for `planning/audit/06-dead-code-and-schema-cruft.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- X-1: Removed the inert run-history setting from schema, UI, tests, and database.
- X-2: Backfilled and dropped `articles.extracted_content`; retained `extraction_metadata` as the documented latest-outcome cache.
- X-3: The reserved signed-in headed-browser control is disabled and explicitly labeled as unavailable rather than silently accepting inert configuration.
- X-4: Future config columns remain available for migrations, but arbitrary user input is no longer cast into them; selection metadata is internal-only.
- X-5: Removed unused publish/enqueue/extraction-eligibility wrappers.
- X-6: Removed duplicate extractor config schemas and defaults from the registry.
- X-7: LiveViews now use event atoms to avoid unrelated reloads.
- X-8: Consolidated shared status, ID parsing, host, blank/present, and URL helpers in `AdminLive.Format`.

## Not Implemented

- X-5 `Intake.list_ungrouped_input_feeds/0`: retained because it has a current caller; the audit's no-caller claim was stale.
- Legacy string-or-integer related-ID parsing remains as a compatibility boundary even though current producers write integers.

## Auditor Notes

- Future columns are intentionally retained without public casting; this prevents inert UI/API promises while preserving inexpensive schema room for already-planned capabilities.
- The extraction metadata cache is small operational state, not a second copy of article content.
