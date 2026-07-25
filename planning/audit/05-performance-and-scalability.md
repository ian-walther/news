# Performance and Scalability

Reconciled 2026-07-25 (second pass). P-1, P-2, and P-5 are resolved. The P-1
residual (per-attempt `:processing_changed` broadcasts driving full requeries
during batches) was fixed in `3070af5` with consumer-side coalescing: the
Processing and OutputFeed LiveViews queue at most one 300 ms refresh timer per
burst, stale timer messages are ignored, and LiveView tests assert a
ten-event burst leaves the render stable until the single queued refresh
applies the latest state.

---

## P-3 — Attempt/run/failure growth (informational, deferred by design)

Unchanged: `runs`, `failures`, `pipeline_step_attempts`,
`article_extraction_attempts` grow without bound until the planned explicit
retention policy exists (`planning/open-questions.md` Retention). The
dashboard's `list_actionable_failure_groups` (newest 500, filtered in memory)
is the first query to degrade. No action now; this entry exists so retention
work starts from these tables.

---

## Explicitly Fine / Leave-Alone

- **P-4 (fresh Chromium per headless extraction):** accepted for isolation
  and operational simplicity. Revisit only when measured headless throughput
  becomes a real constraint.
- **Backfill remains row-oriented for item creation** (side effects per
  item); eligibility and pagination are SQL — accepted shape.
- **Non-processing events refresh inline** (publishing/operations/settings/
  intake changes on the coalescing pages): these are low-frequency; only
  `:processing_changed` needed coalescing. Accepted.
