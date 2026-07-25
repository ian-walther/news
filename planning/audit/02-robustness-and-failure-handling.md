# Robustness and Failure Handling

Reconciled 2026-07-25 (second pass). **No open findings.**

R-1–R-5 and R-7–R-9 are implemented and verified. R-9 (silently swallowed
item-creation errors in the live publish loop) was fixed in `3070af5`:
`publish_article_to_eligible_feeds/1` returns `{feed, result}` pairs, and
`Pipeline.process_raw_items/2` records a `generated_feed_item_create_failed`
failure (feed/article/raw-item/input-feed context, linked to the run) per
failed enrollment and counts it in the run's `item_failures`/status. A
regression test reproduces the previously swallowed error via a corrupt
pipeline definition and asserts the failed run plus failure record.

## Explicitly Fine / Leave-Alone

- **R-6 (fetch/backfill/re-render as supervised tasks, not durable
  dispatchers):** accepted as implemented-by-decision. These operations are
  idempotent, run records provide visibility, startup recovery
  (`Operations.Recovery`) closes interrupted ones as failed, and batch
  enrollment — the case the plan assigns to a dispatcher — has one. Do not
  build a generic operation dispatcher unless a real resumption need appears.
- **Worker kill via `kill -TERM -<pgid>` without `--`:** works with both BSD
  and procps kill for this argument order and is covered by the
  timeout/child-cleanup tests; not worth churn.
