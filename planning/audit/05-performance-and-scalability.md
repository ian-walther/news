# Performance and Scalability

Reconciled 2026-07-25. P-2 (keyset backfill without the 5,000-article cliff)
and P-5 (batched feed loads, conditional new-item render, async Ollama
discovery, de-duplicated feed fetches) were implemented, verified, and
removed. P-1 is partially done; the residual below is the remaining item of
substance.

---

## P-1 (residual) — Per-attempt processing broadcasts still drive full-page requeries during batches

- **Severity:** low-medium (single operator; visible mainly while a batch runs with the Processing page open)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/processing.ex` (`broadcast_on_ok/1` on every attempt/item-step mutation), `newspaper_web/live/admin_live/processing.ex` (`assign_data/2` reloading running/queued/recent/waiting sets — queued capped at 5,000 with 7 preloads), `admin_live/output_feed.ex` (`assign_processing/2` including `feed_step_counts`)

What landed: fetch ingestion batches per-row events into one intake update,
and every LiveView now pattern-matches event atoms so unrelated domains no
longer trigger reloads (verified in `articles.ex`, `processing.ex`,
`output_feed.ex`; the dashboard's catch-all is legitimate since it renders
all domains). That fixed the worst multiplier.

What remains: pipeline execution still emits `:processing_changed` several
times per attempt (queue, running, finish, item-step sync), and the
Processing and OutputFeed pages respond to each by re-running their entire
query set. A 500-article extraction batch still produces a few thousand
full reloads on an open Processing page over its lifetime.

**Decision:** coalesce on the consumer side — in the Processing and
OutputFeed LiveViews, on a relevant event set a `@refresh_queued` flag +
`Process.send_after(self(), :refresh, 300)` token instead of reloading
inline, so bursts collapse to ≤3 reloads/second regardless of batch volume.
(Alternative, one sentence: coalesce on the producer side with a debounced
broadcaster process; consumer-side is simpler and testable with
`render_async`-style assertions.) Keep the existing event-atom filtering.

**Guardrails/tests:** LiveView test that sends N rapid
`{:newspaper_data_changed, :processing_changed}` messages and asserts the
data-assembly function ran once (e.g., via a counting stub around
`Processing.list_processing_attempts/2` or a telemetry counter).

**Effort:** S–M.

---

## P-3 — Attempt/run/failure growth (informational, deferred by design)

Unchanged from the original audit: `runs`, `failures`,
`pipeline_step_attempts`, `article_extraction_attempts` grow without bound
until the planned explicit retention policy exists
(`planning/open-questions.md` Retention). The dashboard's
`list_actionable_failure_groups` (newest 500, filtered in memory) is the
first query to degrade. No action now; this entry exists so retention work
starts from these tables.

---

## Explicitly Fine / Leave-Alone

- **P-4 (fresh Chromium per headless extraction):** accepted for isolation
  and operational simplicity. Revisit only when measured headless throughput
  becomes a real constraint.
- **Backfill remains row-oriented for item creation** (side effects per
  item); eligibility and pagination are now SQL — accepted shape.
