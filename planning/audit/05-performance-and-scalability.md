# Performance and Scalability

Single-operator app, small data today — none of this is an emergency. But the
plan explicitly wants no accidental retention limits and verbose history, so
data only grows; these are the paths that degrade first. A-1 (full-history
reprocessing per fetch) is the biggest item and lives in the architecture
file.

---

## P-1 — Broadcast storm × full-requery LiveViews

- **Severity:** high (first thing to degrade in daily use)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/events.ex` (single topic), all `broadcast_on_ok` call sites (`intake.ex`, `publishing.ex`, `operations.ex`, `processing.ex`), every admin LiveView's `handle_info({:newspaper_data_changed, _event}, socket)`

Every raw-item insert, item render, attempt status change, run update, and
failure insert broadcasts on one topic. Every mounted admin LiveView responds
to **any** event by re-running its entire data assembly:

- `AdminLive.Processing.assign_data/2` reloads running (250) + queued
  (**5,000 cap**) + recent (75) attempts, each with 7 preloaded associations,
  plus waiting steps, counts, operations, and all site policies — per event.
  During an extraction batch, each attempt generates ~4 broadcasts
  (queue, running, finished, item-step updates), so a 500-article batch
  triggers thousands of full reloads on an open Processing page.
- `AdminLive.Articles`, `Dashboard`, `Intake`, `OutputFeed`, `OutputFeeds`
  behave the same with their own query sets (`OutputFeed.assign_processing`
  runs the expensive `feed_step_counts`, see A-4).
- A fetch cycle that stores 100 new raw items emits ≥100 `:intake_changed`
  events (one per insert, `intake.ex:156-161`) plus per-item publish events.

**Fix directions (any subset helps):**
- Debounce in the LiveViews (collapse events within ~250–500 ms; a simple
  `Process.send_after` re-render token is enough).
- Batch broadcasts at the operation level (one event per fetch/publish run,
  not per row).
- Split the topic per domain (`intake`, `publishing`, `processing`,
  `operations`) — half the views can then ignore most events; the
  `handle_info` clauses already pattern-match an `event` atom that is mostly
  ignored today.

---

## P-2 — Backfill is a hard-capped N+1

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:140-172` (`backfill_output_feed/2`), `pipeline.ex:267-276`

`Content.list_articles(5_000)` loads the 5,000 most recent articles **with
four preloaded association trees each**, then filters in Elixir with
`eligible_for_feed?/2`, which re-preloads the feed's memberships *and* the
article's sources **per article** (≈10,001 queries per backfill), then calls
`ensure_item_for_feed` per match. Two problems:

1. Cost: ~2–4 queries per article regardless of eligibility.
2. Correctness cliff: once the pool exceeds 5,000 articles, backfill silently
   ignores older articles with no indication — contradicting "Backfill creates
   missing generated feed items from already-ingested articles"
   (`workflow.md`) with no documented window.

One SQL statement can do the whole thing (insert-select of eligible articles
lacking an item row, feed memberships joined in). At minimum, hoist the feed
preload out of the loop and drop the cap in favor of batched streaming.

---

## P-3 — Attempt/run/failure tables grow forever with no pruning path

- **Severity:** low today, structural later
- **Confidence:** certain
- **Location:** `runs`, `failures`, `pipeline_step_attempts`, `article_extraction_attempts`; plan: `workflow.md` Retention, `open-questions.md`

Deliberately deferred by the plan ("Retention should be an explicit policy") —
this entry just quantifies the pressure: every article on an extract+digest
feed generates ≥2 attempts, ≥2 runs, per-worker attempts, and failures never
resolve or expire (`list_actionable_failure_groups` loads the newest 500 and
filters in memory on every dashboard render). The `runs` table also absorbs a
`pipeline_step` run per attempt execution. When retention arrives, these are
the tables to start with; until then the dashboard failure query is the first
one to slow down.

---

## P-4 — Headless extraction launches a fresh Chromium per article

- **Severity:** low (throughput), acceptable (isolation is a plan goal)
- **Confidence:** certain
- **Location:** `workers/extraction-headless-browser/src/extractor.mjs` (`chromium.launch` per request), `command_worker.ex` (new OS process per attempt)

Every headless attempt pays node start + Playwright + Chromium launch
(~1–2 s) before navigation. The plan wants isolated contexts, which
`browser.newContext()` per request inside one long-lived browser would satisfy
equally well; a persistent worker (stdin-per-line protocol or small HTTP
sidecar) would cut per-article latency substantially once headless volume
grows. Fine to defer; noted so the per-article cost is a known choice.

---

## P-5 — Assorted smaller N+1s / double work

- **Severity:** low
- **Confidence:** certain

- `Publishing.publish_article_to_eligible_feeds/1` runs `Repo.get!` per
  eligible feed per article (`publishing.ex:139-143`).
- `create_item!` renders the item, then `enqueue_item`, then re-renders it
  (`publishing.ex:190-219`) — two renders and two broadcasts per new item.
- `AdminLive.OutputFeed.assign_feed/2` fetches the feed twice back-to-back
  (`output_feed.ex:499-501`).
- `Extraction`/`Digestion` `rerender_article_items/1` reloads each item with
  heavy preloads one at a time (`extraction.ex:312-321`).
- Extraction dispatcher `:recover` calls `Processing.get_attempt!/1`
  (7 preloads) per queued attempt just to compute a host
  (`dispatcher.ex` handle_info `:recover`).
- `Settings` LiveView calls Ollama discovery synchronously in
  `handle_info`/`handle_event` with a 5 s receive timeout, blocking the
  LiveView process (use `assign_async`/`start_async`).
