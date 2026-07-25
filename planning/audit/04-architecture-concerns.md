# Architecture Concerns

Structural issues. None of these break today at current scale; all of them
tax every future feature, and several will bite as data grows.

---

## A-1 — Fetch pipeline reprocesses all history on every cycle

- **Severity:** high (the single biggest structural debt)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:31-134` (`fetch_input_feed` → `process_feed_boundary` → `process_intake_group`/`process_input_feed`)

The design is: after each single feed fetch, load **every raw item ever
stored** for the feed's whole intake group, re-run dedupe/canonicalization on
each, and re-check output-feed eligibility per article
(`Publishing.publish_article_to_eligible_feeds` per raw item). Consequences:

- Work per fetch cycle is O(total history), forever growing (no retention
  policy exists yet, by design).
- An intake group with N feeds is fully reprocessed N times per `fetch_all`
  cycle (once per member feed fetched).
- Each pass re-runs `maybe_update_representative` per article
  (`Repo.preload` + timestamp compare) and `ensure_item_for_feed` per
  article×feed (a `Repo.get_by` each), even though nothing changed.
- Each fetch broadcasts `:intake_changed` per *new* raw item plus
  `:publishing_changed` per created item, which the LiveView layer multiplies
  into full-page requeries (see P-1).

The eager-durable-intake plan does not require this: it requires that
*discovered* items be processed eagerly. Processing only the raw items
discovered by the current fetch (plus an explicit "reprocess group" manual
action for dedupe-rule changes) preserves all planned semantics with O(new
items) work. The current shape also widens the concurrency window that makes
C-4/C-5 races realistic.

**Fix direction:** have `fetch_input_feed` collect the raw items it
inserted/found and pass exactly those to canonicalization; keep a manual
"reprocess intake group" operation for recovery; make `fetch_all` process each
intake group at most once per cycle.

---

## A-2 — Article-level extraction state is triplicated and synchronized by hand

- **Severity:** high
- **Confidence:** certain
- **Location:** `articles.extraction_status/extracted_content/extraction_metadata` (`content.ex:396-400, 537-659`), `article_extractions` (artifact), `generated_feed_item_steps.status` (+ `pipeline_step_attempts.status`)

The same fact ("is this article extracted?") lives in three places with
hand-rolled synchronization:

- `articles.extraction_status` mutated in at least six places
  (`set_extraction_status` from enqueue and from `execute_attempt`,
  `record_extraction_success/failure/no_content`, plus `fail_execution`).
- `generated_feed_item_steps` rows updated via `update_attempt_item_steps`
  (keyed by `latest_attempt_id`), `advance_item_step`, `skip_article_steps`,
  `reactivate_skipped_article_steps`.
- The v1 columns `articles.extracted_content` / `extraction_metadata`
  duplicate the artifact table (see X-2).

The migration history shows this evolved (v1 articles-only → artifact table →
item-step snapshots), and each layer patched the previous one instead of
replacing it. Symptoms already present: C-6 (history clobbering), the
`requested_status/forced_status` matrix re-deriving item-step status from
article status (`processing.ex:1132-1163`), and `feed_step_counts`
reconstructing "missing" states by subtraction with three compensating count
queries (`processing.ex:188-245, 1275-1344`) because items created before a
step existed have no step rows.

**Fix direction:** pick one authority per question. Reasonable target:
`article_extractions` (artifact presence) + latest attempt (in-flight state)
are authoritative; `articles.extraction_status` becomes a derived cache with a
single writer (or is dropped and queried via join — the article list already
joins for filters); item-step rows get created eagerly for all items when a
step is added (making `feed_step_counts`'s subtraction heuristics
unnecessary — see A-4).

---

## A-3 — Domain layer reaches into the web layer and bakes absolute URLs into snapshots

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/publishing.ex:332-346` (`rendered_link_url/3` calls `NewspaperWeb.Endpoint.url()`)

`Newspaper.Publishing` (domain) depends on `NewspaperWeb.Endpoint` (web) to
build hosted-article links, inverting the intended dependency direction, and
persists the absolute URL into rendered snapshots. Changing `PHX_HOST`/scheme
(the plan expects moving hosts: nginx today, maybe TLS later) silently leaves
all existing snapshots pointing at the old host until a manual re-render of
every feed. Options: store a relative path and absolutize at render-time in
the controller (still deterministic — the snapshot decision "hosted vs
original" is what needs to be durable), or keep absolute URLs but make host
part of render-source metadata so a host change can trigger a scoped
re-render.

---

## A-4 — `feed_step_counts` derives state by subtraction instead of representing it

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/processing.ex:188-245, 1275-1344`

Because items that existed before a pipeline step was configured have no
`generated_feed_item_steps` row, per-step counts are computed as: all item
counts, minus represented statuses, then three extra aggregate queries
guessing how many of the "missing" rows would be ready / terminal-failed /
blocked, with `max(_, 0)` clamps guarding against the heuristics
disagreeing. This is the hardest-to-follow code in the app, runs on every
output-feed page render *and* every data-changed broadcast, and will produce
subtly wrong operator counts whenever a new state is added (it already treats
only extraction/digestion specially).

**Fix direction:** materialize item-step rows (status `not_requested`) for
existing items when a step is created — the plan's future-only semantics are
about *scheduling work*, not about withholding bookkeeping rows — after which
the counts collapse to one GROUP BY.

---

## A-5 — Two dispatchers, three ad-hoc task-execution styles

- **Severity:** medium
- **Confidence:** certain
- **Location:** `processing/dispatcher.ex`, `digestion/dispatcher.ex`, `processing/batch_dispatcher.ex`, plus bare `Task.Supervisor.start_child` calls in `pipeline/scheduler.ex`, `admin_live/output_feed.ex`, `admin_live/intake.ex`, `admin_live/dashboard.ex`

The extraction dispatcher (per-host state machine), digestion dispatcher
(single queue), and batch dispatcher (task registry with monitors) share no
code but re-implement overlapping concerns: recovery on init, enqueue
deduplication, "finished" bookkeeping, task supervision. Only BatchDispatcher
monitors its tasks (hence R-1 applies to the other two). A single generic
"serial queue worker" abstraction (host-keyed for extraction, singleton for
digestion) with monitor-based completion would remove the wedge class of bugs
and halve the GenServer code. This is exactly the point where the plan says
Oban could be reconsidered "if the job surface grows" — three hand-built
dispatchers with divergent semantics is a reasonable definition of grown; at
minimum, unify the hand-built ones.

---

## A-6 — Output-feed eligibility logic exists twice

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:267-276` (`eligible_for_feed?/2`, used by backfill) vs `newspaper/lib/newspaper/publishing.ex:363-391` (`eligible_generated_feed_ids/2`, used by live publishing)

Same business rule ("which feeds should carry this article"), two independent
implementations with different shapes (per-article-per-feed boolean with
preloads vs set query). They can drift — D-8's enabled-feed question would
have to be fixed in both — and the backfill version is a severe N+1 (P-2).
Consolidate into one query-based function in `Publishing` used by both paths.

---

## A-7 — `Pipeline` vs `Processing` boundary is blurry

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex`, `newspaper/lib/newspaper/processing.ex`

`Pipeline` owns fetch/dedupe/backfill/re-render + failure retry dispatch;
`Processing` owns pipeline steps/attempts/batches; `Publishing` owns items but
also triggers processing (`create_item!` calls `Processing.enqueue_item`);
`Extraction`/`Digestion` call back into `Processing`, `Content`, `Publishing`,
and `Operations`. The cycle Publishing→Processing→(Extraction|Digestion)→Publishing
(re-render) makes the "control plane advances workflow" story hard to trace —
e.g., item creation both renders and enqueues and then re-renders
(`publishing.ex:190-219`). Not urgent, but when A-2 is addressed, consider
making item creation emit a plain "item created" event handled by one
orchestrator, so rendering and enqueueing have a single owner.

---

## A-8 — Admin surface and feeds have no authentication story

- **Severity:** medium (decision to confirm, not necessarily a defect)
- **Confidence:** certain (no auth exists); unknown (whether accepted)
- **Location:** `newspaper_web/router.ex` (single unauthenticated browser scope), `docker-compose.prod.yml` (port 4000 published on the host), README (nginx on `news.home`)

Every destructive operation (delete feeds/groups/policies, trigger batches,
change settings) is available to anyone who can reach `news.home`, and the
prod compose publishes 4000 directly in addition to nginx. The planning docs
scope security effort to Chrome/CDP/VNC (`prod-topology.md`) and never
mention app auth, so "trusted LAN only" is presumably the accepted posture —
but it deserves an explicit line in `architecture.md`, plus closing the
redundant direct port-4000 exposure if nginx fronts the app. Also note RSS
endpoints are unauthenticated by design (FreshRSS needs them) — fine, but
hosted article pages (`/articles/:guid`) expose extracted paywalled content to
the same LAN; acceptable in-house, worth stating.

---

## A-9 — Feed XML rendering by string concatenation

- **Severity:** low (beyond the C-3 bug)
- **Confidence:** certain
- **Location:** `newspaper_web/controllers/feed_controller.ex`

Beyond the CDATA bug, hand-built XML makes every future field (enclosures,
`dc:creator`, `content:encoded`, atom self-link) an escaping exercise.
`Saxy`'s builder or even a small EEx template with explicit escaping would
centralize this. Low priority until D-3/C-1 add fields.
