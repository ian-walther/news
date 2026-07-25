# Dead Code and Schema Cruft

Reconciled 2026-07-25. **No open findings.** X-1–X-4 and X-6–X-8 were
implemented and verified (inert run-history setting removed schema-to-DB;
legacy `articles.extracted_content` backfilled into `article_extractions` and
dropped; the reserved auth flag disabled and labeled; future config columns
kept but no longer cast from input; vestigial registry config schemas removed;
event atoms actually used; shared helpers consolidated into `AdminLive.Format`
with thin delegates).

## Refutation (audit was wrong; implementer was right)

- **X-5, `Intake.list_ungrouped_input_feeds/0`:** the audit claimed it had no
  callers; it is called by the Intake LiveView
  (`admin_live/intake.ex`, ungrouped-feeds section). The function was
  correctly retained. The other X-5 removals (`publish_output_feed/2`,
  `Processing.enqueue_feed/2`, `Processing.enqueue/4`,
  `extraction_eligible_article_ids/1`) were real and are gone. Lesson for
  future passes: verify caller claims with a grep at write-time, not from
  memory of the read-through.

## Explicitly Fine / Leave-Alone

- **Future-capability columns** (`generated_feeds.policy_config`,
  `intake_groups.dedupe_config`, `input_feeds.default_metadata`,
  `generated_feed_items.selection_metadata`): intentionally retained in the
  schema for planned work, no longer publicly castable;
  `selection_metadata` is written internally only. Do not re-flag.
- **String-or-integer related-ID parsing** in `Operations.related_id/2` and
  failure retry validation: retained as a compatibility boundary for
  historical rows even though current producers write integers. Accepted.
