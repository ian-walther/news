# Robustness and Failure Handling

Reconciled 2026-07-25. R-1–R-5, R-7, R-8 were implemented (dispatcher task
monitoring, terminal invalid-URL failures, run-record cleanup on crash paths,
process-group worker termination + tini, startup operation recovery, logged
scheduler fallback + settings singleton, validate-before-increment retries),
verified, and removed. One new low finding from the reconciliation diff review,
plus one leave-alone verdict.

---

## R-9 — Item-creation errors in the live publish loop are silently swallowed

- **Severity:** low
- **Confidence:** certain (code path); not observed at runtime
- **Location:** `newspaper/lib/newspaper/publishing.ex` — `publish_article_to_eligible_feeds/1` (`Enum.map(&create_item_if_missing(&1, article))`), callers in `newspaper/lib/newspaper/pipeline.ex` (`process_raw_items/2`)

`create_item_if_missing/2` now correctly propagates `{:error, changeset}`
(introduced with the C-5 upsert work), but `publish_article_to_eligible_feeds`
just maps the results and no caller inspects the list. `process_raw_items`
only rescues **raised** exceptions, so a changeset-error return — e.g., a
render-attrs validation failure, or `Processing.enqueue_item` failing inside
`create_item`'s `with` — produces no failure record, no run error count, and
no log. The article silently never appears in that output feed.

**Decision:** in `publish_article_to_eligible_feeds`, collect `{:error, _}`
results and record one `Operations.create_failure` per failed feed
(`failure_type: "generated_feed_item_create_failed"`, related feed + article
IDs), returning `{results, errors}` or raising into the caller's existing
per-item rescue so the fetch run's `item_failures` count includes them.
Either shape is fine; pick the one that keeps `process_raw_items`'s error
accounting accurate.

**Guardrails/tests:** a test that forces `create_item` to fail (e.g., stub an
invalid render or delete the feed concurrently) and asserts a failure record
plus a non-`succeeded` processing run.

**Effort:** S.

---

## Explicitly Fine / Leave-Alone

- **R-6 (fetch/backfill/re-render as supervised tasks, not durable
  dispatchers):** accepted as implemented-by-decision. The implementer's
  boundary holds: these operations are idempotent, their run records provide
  visibility, startup recovery (`Operations.Recovery` +
  `fail_interrupted_operation_runs/0`) now closes interrupted ones as failed,
  and batch enrollment — the case the plan explicitly assigns to a dispatcher —
  already has one. Do not build a generic operation dispatcher for these
  unless a real resumption need appears.
- **Worker kill via `kill -TERM -<pgid>` without `--`:** works with both BSD
  and procps kill for signal-then-target argument order and is covered by the
  timeout/child-cleanup tests; not worth churn.
