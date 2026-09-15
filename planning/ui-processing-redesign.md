# Processing UI Redesign

## Roles and how to use this document

- **Ian** owns product decisions (see Decision log). Nothing in this document
  is open unless it appears under "Questions for the auditor".
- **Fable** implements, phase by phase, in the order under Implementation
  plan, following AGENTS.md (test-first for behavior changes, full suite
  before finishing). Commit/push/deploy is suspended for this effort: nothing
  is committed until the whole redesign is done (Decision log).
- **Astra** audits: first this plan for blind spots before phase 1 starts,
  then each landed phase against the plan. Findings go in
  `planning/audit/` per the existing audit process (stable IDs, decisions
  not options, forward-facing docs). Contradictions between this plan and
  code reality are findings, not reasons to silently diverge.

Everything above the Implementation plan is the *what and why*; the
Implementation plan is the *how*, at the level of detail an auditor needs to
spot what is missing.

## Why

Scheduling, following, and following up on background work is spread across
six pages, each showing a slightly different slice of the same state with a
slightly different set of controls. Observed on production on 2026-09-14
(11,029 articles, a 2,810-item digestion retry queue in flight):

| Question an operator asks | Where the answer lives today | What it says |
| --- | --- | --- |
| How much work is queued? | Activity tile "Processing" | **0** (tile counts extraction only, unlabelled as such) |
| | Articles → Digestion → Processing filter | **2,806** |
| | Processing → "Queued next" | **2,810** |
| Is that batch running? | Activity → "Extraction batches" (it is a digestion batch) | "Running · **Waiting to start** · 37m" — it has hundreds of queued attempts; the summary line only prints succeeded/failed/skipped |
| | Output feed → Recent processing | "185 succeeded · 3 failed · 159 queued · 1 running" |
| When will it finish? | nowhere | — |
| What is broken and what do I click? | Activity "Needs attention" (failure *records*, "Retry latest") | 1 group |
| | Output feed page ("Retry 3 failed digestions" batch) | per feed, per step |
| | Articles → Failed filter (per-article Re-extract / Digest) | per article |
| | Sites / Activity ("Try now" for backoff) | per host |
| Is digestion paused? | Settings ("Running") | but the Cars page button reads "Existing-item processing paused" |

Every one of those pages is individually reasonable. Together they violate
the two rules that make operational UIs legible: **one concept has one
home**, and **controls live where the state they act on is shown**. The page
literally named Processing is the only page with *no* controls.

## Principles

1. **One home per concept.** Queue state, batches, failures, and pipeline
   configuration each appear in exactly one authoritative place; every other
   page shows at most a summary count that links there.
2. **Controls live with state.** Pause/resume, retry, try-now, start batch,
   cancel batch all live on the console that displays the thing they act on.
   Settings holds configuration (URLs, models, intervals), not operations.
3. **The superset rule.** When a new page or table is a strict superset of
   an old one, the old one is removed. When the old one is mostly but not
   fully obviated, it is either merged or kept explicitly stripped down; it
   is never left as a second, slightly different view of the same thing.
4. **Verbs say what they do.** No operator-facing word may need the code to
   explain it. "Backfill" is banished (see Vocabulary).
5. **Steps are generic.** The pipeline is an ordered list of registered step
   types (extraction, digestion, filtering later, rendering later). The UI
   renders whatever the registry declares; nothing hardcodes "extraction and
   digestion" as the two things a feed can do. Step prerequisites are
   declared on the registry entry, not in a LiveView.
6. **One status vocabulary.** The same eight words everywhere, from one
   helper: `Not requested · Waiting · Queued · Running · Ready · Failed ·
   Skipped · Cancelled`. Counts on any page are labelled with what they
   count *and in which unit* (articles, output item steps, executions, batch
   members) — the same word across pages never implies the same total.
7. **Progress is a rate, not a spinner.** Anything queued shows throughput
   and an estimate ("185 of 348 · 4.7/min · ~35 min left"). Attempts already
   carry the timestamps.
8. **Failures are derived, not filed.** The attention inbox is computed from
   current state (failed item steps, failed fetches, active site backoff,
   stuck runs), grouped by cause, with one correct action per group. Fixing
   the cause clears the entry; no acknowledge/dismiss lifecycle
   (consistent with `workflow.md`).
9. **V2 is a strict superset of today.** The Reading Feed, its output feeds,
   and their processing remain. V2 adds source-scoped enrichment
   (extraction and classification move upstream to Outlets/Input Feeds per
   `planning/newspaper/domain-model.md`) and later output-scoped steps
   (filtering). The redesign must accommodate both scopes so nothing built
   now is thrown away at Phase 2.

## Vocabulary

Every operation gets a verb that states its effect. Helper text (tooltip or
subtitle) carries the second sentence where shown.

| Today | Proposed label | What it actually does |
| --- | --- | --- |
| Backfill | **Add matching articles** | Creates feed items for already-ingested articles that match this feed's sources; new items enter the pipeline like fresh ones. Does not extract or digest anything by itself. |
| Re-render | **Refresh RSS output** | Regenerates stored RSS snapshots from stored artifacts and current rendering settings. Fetches nothing, processes nothing. |
| Process existing | **Run *step* on existing items** | Starts a batch over this feed's items where *step* was never requested. |
| Retry N failed digestions | **Retry failed *step*** | Starts a batch over this feed's items where *step* failed. |
| Re-extract / Digest (per article) | **Re-run *step*** | Forces one article through *step* again, ignoring any existing artifact. |
| Retry latest / Retry site now | **Retry** / **Try now** | Inbox-group retry; bypass a site's backoff timer once. |
| Extract future articles (toggle) | **Enabled** column per step | Whether new items request this step. |

Statuses: `Not requested · Waiting · Queued · Running · Ready · Failed ·
Skipped · Cancelled`, one helper, everywhere. `Cancelled` is operator
withdrawal and is never treated as a no-content skip.

## Target information architecture

```text
Processing (home, "/")   — THE operational console
  ├─ Queue      live stages, throughput, ETA, pause/resume, site pacing + try now
  ├─ Batches    every batch across feeds, real progress, start/cancel, retry-failed
  ├─ Attention  derived failure inbox grouped by cause, one action per group
  ├─ Pipeline   step-generic tables: source enrichment + output processing
  └─ History    attempts, operations, failure records; filterable
Sources                  — input feeds + intake groups + website policies (config only)
Outputs                  — output feed list; feed page = membership + rendering + two feed verbs
Articles                 — the library; per-article Re-run actions stay
Settings                 — fetch interval, Ollama URL and model. Nothing operational.
```

Navigation drops from seven items to five. The superset rule applied:

| Existing surface | Verdict | Reason |
| --- | --- | --- |
| Per-feed processing panels (Output feed page) | **Removed** | Strict subset of Pipeline tab |
| Activity: Needs attention, batch list, site pacing | **Removed** | Strict subsets of Attention / Batches / Queue |
| Activity: article-health tiles, recently extracted, latest fetch | **Removed; page deleted** (decided 2026-09-14) | Article health becomes a Queue summary line; recently extracted is Articles' default sort; latest fetch moves to the Sources header |
| Sites page | **Kept, stripped, folded into Sources** | Policy configuration is not a subset of Queue's live state; its operational bits (backoff display, Try now) move to Queue |
| Old Processing page | **Kept, stripped, becomes History** | Running/queued/waiting move to Queue; the remainder is a strict subset |
| `failures` table "Needs attention" | **Removed as a to-do list** | Superseded by derived Attention; records stay browsable under History |
| Settings: Pause digestion | **Moved** to Queue | Operational, not configuration |
| `/runs` alias | **Removed** | |

## Page-by-page

### Processing → Queue (home)

One card per stage, generated from the registry, each the single source of
truth for that stage:

- **Extraction:** queued / running / paused-by-site counts; throughput; the
  per-host list with pacing or backoff state and **Try now** (moves here from
  Activity and Sites).
- **Digestion:** queued / running; model in use; **Pause / Resume** (moves
  here from Settings); throughput and ETA ("2,810 queued · 4.7/min · ~10 h").
- Future step types (filtering) get a card automatically.

Below: **Running now** (all stages, one list) and **Queued next** per stage,
grouped by batch or feed rather than a flat position list. A one-line
article-health summary (articles · ready · needing attention) replaces the
Activity tiles.

### Processing → Batches

All `pipeline_batch` runs across all feeds, running-first. Each row: feed,
step, selection (existing / failed), `done of total`, rate, ETA, started,
**Cancel** (new, decided 2026-09-14; contract C2 — withdraws this batch's
demand, marks its unstarted members Cancelled, lets running work finish,
leaves shared work for other demand, closes the run).
Header action: **Start batch…** (feed + step + selection). The only place
batches start apart from the Pipeline row menus, which open the same picker
pre-filled.

### Processing → Attention

A tab inside Processing (decided 2026-09-14), with the group count shown as
a badge on the Processing nav item. The unified inbox, derived rather than
filed:

| Group | Derived from | Action |
| --- | --- | --- |
| *Step* failed · *kind* · *feed or host* | item steps `failed`, grouped by step, failure kind, and feed (output steps) or host (source steps) | Retry group (a `failed`-selection batch) |
| Site backoff · *host* | policy `backoff_until` in the future | Try now |
| Feed fetch failed · *feed* | input feed `last_fetch_status = failed` | Refetch |
| Stuck · *run* | run `running` past a threshold with no attempt activity | Close as failed |

Each group expands to its items with per-item **Re-run**. Queue's header shows
the group count with a link here.

### Processing → Pipeline

**The pipeline is an ordered chain, so the display is a chain, not a
table.** Verified in code: `pipeline_steps.position` orders every listing,
and `Processing.advance_item/2` walks an item's steps in position order and
halts at the first step that is not succeeded or skipped — a later step
cannot run until everything before it is done. Reordering
(`Processing.move_step/2`) exists in the domain layer but has never been
exposed in the UI, and the only ordering that works today is
extraction → digestion because prerequisites are hardcoded and nothing
validates position against them (digestion placed first would block and
deadlock the chain). The ordering was designed for the filtering case:
filter-then-digest saves model work; digest-then-filter lets a filter read
the digest. Both are legitimate per-feed choices.

Layout: one row per feed; the row is its chain —
`extraction → digestion → …` — where every link is the same cell
component: step name · enabled toggle · coverage (`ready / total`, queued,
waiting, failed) · a ⋯ menu with **Run on existing items**, **Retry
failed**, **Remove step**. A **+ Add step** control (registry picker) replaces
today's create-step toggles and inserts the step at its canonical position.
Because execution halts at the first pending link, a queued or failed chip
visibly explains why every chip after it is waiting — the arrows carry the
meaning the table could not.

**Order is canonical, not configurable** (decided 2026-09-14). The registry
declares one global step order (extraction → filtering → digestion → …) and
prerequisites; `position` is derived from it when a step is added, and
`Processing.move_step/2` is deleted. This removes the latent deadlock
ordering entirely and keeps the Pipeline tab the single configuration
surface (enable / add / remove); nothing else configures the pipeline
besides the code registry.

- **Source enrichment** — one chain per source; steps are extraction and,
  in V2, classification. *Today this section is empty*: extraction is still
  output-scoped in the data. When V2 Phase 2 moves extraction's row unit to
  Outlets/Input Feeds, the extraction link moves from the output chains to
  the source chains and nothing else changes.
- **Output processing** — one chain per output feed; steps are (today)
  extraction and digestion, later filtering. Rendering settings are not steps
  and stay on the feed page.

### Processing → History

Today's Processing page content — recent attempts and operations with the
stage and feed filters — plus the historical `failures` records. Article- and
batch-context deep links keep working.

### Output feed page

Membership, rendering settings, and exactly two feed-scoped verbs in the
header: **Add matching articles** and **Refresh RSS output**. A one-line
per-step coverage summary ("Extraction: 1,371 of 1,371 ready · Digestion:
1,208 ready, 3 failed → Attention") links into the Pipeline row and the
Attention groups. No toggles, no batch buttons.

### Sources

Intake groups and input feeds as today, plus website policies as a second
section (starting extractor, pacing interval, timeout, minimum text length,
escalation flag). The Sources header carries the latest global fetch status
and **Fetch all now**. No live pacing state and no Try now — those are Queue.

### Articles

Unchanged in structure; adopts the shared status vocabulary; per-article
actions become **Re-run extraction / Re-run digestion** (and any future
step); per-article history moves into an expandable row rather than linking
out to a filtered History.

### Settings

Fetch interval, Ollama URL, model. Nothing else.

## Registry and domain changes implied

To make the UI step-generic, the registry entry for a step implementation
gains: `scope` (`:source` | `:output`), `prerequisites` (list of step types),
a canonical `order` index, and `label`s for the verbs. The LiveViews stop
enumerating step types. `Processing.prerequisites_ready?/2` reads the
registry instead of hardcoding digestion→extraction; `create_step` derives
`position` from the registry order; `Processing.move_step/2` is deleted
(never had a UI caller). Existing `pipeline_steps` rows already match the
canonical order, so no data migration is needed beyond a one-time
normalization of `position`.

## Straight bugs and label defects to fix regardless

- `Format.run_summary/1` prints "Waiting to start" for any batch with only
  queued/running attempts; it omits queued and running counts.
- Activity's batch section is headed "Extraction batches" for every batch
  type.
- Activity's "Processing" tile counts extraction only and does not say so
  while digestion has thousands queued.
- Output feed button labels encode a state machine
  ("Existing-item processing paused", "Failed-digestion retry paused",
  "Waiting for extraction").
- Intake shows "Never fetched" beside a populated "Last fetched" timestamp
  for feeds whose last status was `not_modified`.
- Two "Try now" implementations (Activity, Sites) with copy-pasted handlers.

## Implementation plan

Four phases, each independently shippable and deployed on its own. Every
phase ends with the full Elixir suite green and a production smoke check of
the pages it touched.

**Status 2026-09-14: all four phases are implemented in the working tree
(uncommitted, per the Decision log) and `scripts/precommit.sh` is clean
(162 Elixir tests, worker tests). Each phase heading below carries a status
block naming what was delivered, where the implementation deliberately
narrowed or diverged from this plan, and which planned guardrail tests were
not written. Those blocks are the audit's starting point; the production
smoke check has not been done because nothing is deployed.**

**Scope correction (after audit `planning/audit/01-ui-processing-plan.md`,
2026-09-14).** This is not presentation-only. Three pieces are lifecycle
work in the `Processing` domain and are specified as contracts below:
batch cancellation (UI-01/03), durable batch membership distinct from
attempt ownership (UI-02), and centralized step-mutation validation
(UI-04). Everything else remains read models and LiveViews. The escalation
ladder, backoff, automatic retry budget, restart recovery, enrollment,
foreground priority, and attempt deduplication are preserved as-is; the
contracts below add checks to those paths, they do not replace them.

### Invariants every phase must preserve

- Generated feed item GUIDs, RSS output, and `FeedController` are untouched.
- Attempt deduplication (one active attempt per article × step type) and
  foreground-before-bulk priority are unchanged.
- Every existing operator action remains reachable at every deploy boundary
  (nothing is removed before its replacement ships in the same phase).
- Existing deep links (`/processing?article_id=…`, `?batch_run_id=…`,
  `?generated_feed_id=…&stage=…`) resolve to the right tab with the
  context applied, not merely to a page (route matrix in Phase 3).
- The `:processing_changed` refresh coalescing survives in every new
  LiveView; time-derived state (backoff expiry, throughput windows) refreshes
  on a bounded server tick, not only on events.
- No new casting of programmatic fields; no `String.to_atom` on input;
  browser-provided IDs are re-validated server-side against the selection
  they claim to belong to.

### Domain contracts (from the audit; implemented in Phases 2–3)

**C1 — Batch membership (UI-02).** A new table `pipeline_batch_members`
(`batch_run_id`, `generated_feed_item_step_id`, `outcome`, timestamps)
records which item steps a batch *requested*, written durably at enrollment
before any attempt is created or joined. Batch progress, rate, ETA, and
completion derive from members and their batch-scoped outcomes, never from
`pipeline_step_attempts.batch_run_id` alone (which remains as the
foreground/bulk priority signal and execution lineage). An attempt joined by
several batches counts toward each; a member's terminal outcome is retained
when the same item is re-requested by a later batch. Retry attempts
(`retry_attempt/2`, `schedule_automatic_retry/1`) carry the originating
member's batch so bulk retries do not silently become foreground work.
Existing batches get members backfilled from their current attempts in the
migration.

**C2 — Cancellation (UI-01).** `Processing.cancel_feed_batch/1`:

1. In one transaction: set the run's `related["cancelled_at"]`, mark every
   member whose item step is `queued`/`pending`/`blocked` with outcome
   `cancelled`, and set those item steps to a new status `cancelled`
   (distinct from `skipped`; see C3). Attempts are touched only if *no other
   demand* (another batch member or a foreground item step) references
   them; such attempts become `skipped` with `failure_kind: "cancelled"`.
2. After commit: `Dispatcher.remove/1` on both dispatchers by attempt id
   (best effort; step 3 makes it safe if delayed).
3. Enrollment (`enqueue_batch_items`), attempt claiming
   (`mark_attempt_running` becomes a conditional `queued → running` update
   that returns `{:error, :not_queued}` when the row was cancelled or
   already claimed), retry creation (`schedule_automatic_retry`,
   `retry_attempt`), and restart recovery (`requeue_interrupted_attempts`,
   `resume_feed_batch`) all consult the cancelled state and drop cancelled
   work. A dispatcher that pops a cancelled id skips it without failing the
   host.
4. A `running` attempt finishes normally; `refresh_batch_run` may not reopen
   a cancelled run, and closes it (status `cancelled`) once no member is
   active. Repeated cancel is a no-op.

**C3 — Cancellation is not no-content (UI-03).** `cancelled` is its own
item-step status (vocabulary gains an eighth word, shown as "Cancelled").
`advance_item` treats it like `not_requested` (halts; does not continue past
it); `reactivate_skipped_article_steps` does not touch it. **Cancellation
cascades downstream** (decided 2026-09-14): cancelling a batch of step X
also cancels, for the same items, every later step in the chain that is
`pending`, `blocked`, or `queued` — those requests existed only because X
was expected. Steps already `running` finish; steps already `succeeded`,
`failed`, or `skipped` are untouched. The cancel result reports counts per
step ("348 extractions and 348 digestions cancelled"). Re-queueing is the
safety valve and must be one action: the Pipeline link menu and Start-batch
picker gain selection `:cancelled` ("Run on cancelled items"), and running
it on step X re-requests X *and* re-creates the downstream demand that was
cancelled with it, so an accidental cancel is fully reversible in one click.

**C4 — Step mutation validation (UI-04).** All add / enable / disable /
remove logic moves into `Processing` (`create_step/2`, `update_step/2`,
`delete_step/1`) and enforces: prerequisites on add/enable; dependents on
disable/remove (cannot disable extraction while digestion is enabled);
rendering dependencies on disable/remove (cannot remove digestion while a
feed's title or body source is digest; cannot disable extraction while
extracted body or hosted links are selected). Errors are the existing atoms
plus `:rendering_depends_on_step`. Removal with queued/running work is
refused with a reason. Item-step snapshot rows are never rewritten by a
definition change: re-adding a removed step creates rows in canonical
position for items lacking them and leaves historical rows alone; the chain
display renders the *definition* order and shows an item-level notice when
an item's snapshot order differs. The LiveView-side validation is deleted,
not duplicated.

**C5 — Pre-pipeline failure projection (UI-05).** Failures recorded before
an item step exists (`raw_item_ingestion_failed`, `raw_item_processing_failed`,
`generated_feed_item_create_failed`, `rerender_output_feed` item errors)
gain a `resolved_at` column on `failures`, set when the affected entry is
later processed successfully (matched by `raw_item_id`, or by
`input_feed_id`+`feed_guid`/`url` when no raw item exists, or by
`generated_feed_id`+`article_id`). Attention derives these groups from
unresolved failure rows; a later fetch's `ok`/`not_modified` status does
**not** resolve them. The group action is "Retry entry": replay the stored
raw item when one exists; otherwise force a validator-free refetch of the
feed and report honestly when the publisher no longer offers the entry.
Additionally, `process_feed_response` stops saving cache validators when any
item failed, so the next cycle re-receives the entries instead of a 304.

**C6 — Liveness before "Close as failed" (UI-06).** Attention shows three
distinct states for a long-running operation: *expected wait* (paused
queue, host in backoff, behind foreground work, live Ollama request within
its timeout — with the reason and relevant timestamps), *slow* (past the
stage's expected duration but with recent progress), and *abandoned* (no
owning process: the run's task is not alive in `Processing.TaskSupervisor`
or the batch has no dispatcher entry, and no attempt changed state within
the stage timeout). Only *abandoned* offers **Close as failed**, and the
close is a conditional update that fails if the run finished meanwhile.
Stage timeouts: fetch = 2× `receive_timeout`; extraction = policy
`timeout_ms` × chain length + pacing; digestion = Ollama request timeout;
re-render = proportional to item count.

**C7 — Group retry scope (UI-11).** `start_feed_batch/4` gains a selection
`{:items, item_step_ids}` whose membership is snapshotted into
`pipeline_batch_members` at creation, so restart recovery re-enrolls exactly
that set. IDs are validated server-side against the group's predicate (feed,
step type, current status) and silently dropped if stale. Per-item Re-run
from Attention is item-scoped (`request_item_step/3` on that item), not
article-wide; article-wide re-run remains the Articles page action.
Eligibility (active batch for the same feed/step, paused digestion, missing
model, disabled step) moves into `start_feed_batch` and is returned as
reasons the UI renders as disabled-with-reason; a duplicate start while a
matching batch is active is rejected, making double clicks idempotent.

### Read-model contracts (UI-07, UI-08, UI-10)

- Every display states its unit: Queue counts *executions* (attempts);
  Batches counts *members*; Pipeline counts *output item steps*; the
  article-health line counts *canonical articles*. Aggregate-to-detail links
  carry the same predicate as the aggregate.
- "Waiting" splits into *requested, blocked on prerequisite* and *never
  requested* (bookkeeping rows); the chain shows the reason.
- Feeds show a *held* count (items with `publication_status = processing`)
  beside coverage, with a drill-down reason; "Ready" for a step never implies
  published.
- Rate = executions completed per minute over a trailing window, excluding
  artifact reuse and cancellations. ETA is shown only when defensible:
  omitted when the stage is paused, the host is in backoff, fewer than N
  samples exist, or remaining work is blocked on a prerequisite; it counts
  only eligible remaining members. Fake-clock unit tests cover windows and
  expiry.
- Live refresh: LiveViews subscribe to all contributing events
  (`:processing_changed`, `:operations_changed`, `:intake_changed`,
  `:settings_changed`, `:site_extraction_policies_changed`) through one
  coalescer, plus a bounded server tick (30 s) for time-derived state; only
  the active tab's bounded detail list is queried. The nav badge is one
  cached count refreshed by the same coalescer.
- Registry metadata (`scope`, `order`, `prerequisites`, labels) drives
  presentation and configuration only, for the two implemented operations.
  Readiness and artifact reuse stay typed per step (`prerequisites_ready?/2`
  keeps requiring an actual `ArticleExtraction`, never "a preceding step
  terminated"). The Add-step picker lists only executable implementations.
  The source-enrichment section is a labelled empty state; its row unit,
  ownership, and counts are defined by the V2 migration, not here.

### Phase 1 — Vocabulary, counts, rate (no schema change)

*Status: implemented 2026-09-14 in the working tree (uncommitted), ready for
audit. Delivered: `Format.work_status_label/1` and
`work_status_badge_class/1` with all pages delegating; batch summaries with
queued/running; `Processing.stage_throughput/2` and `batch_progress/2` with
ETA omission reasons, rendered via `Format.progress_summary/1` on dashboard
and feed-page batch rows; unit-labelled dashboard tiles with a per-stage
in-progress count; verb renames and disabled-with-reason titles; Intake
`not_modified` shown as healthy; cache validators withheld after a partial
fetch failure. Tests: `format_test.exs`, `processing_progress_test.exs`,
`intake_status_test.exs`, plus updated dashboard/feed/articles/fetch tests.*

- `Format`: one `status_label/1` / `status_badge_class/1` for the eight-word
  vocabulary (`Not requested · Waiting · Queued · Running · Ready · Failed ·
  Skipped · Cancelled`); every LiveView delegates.
- `Format.run_summary/1` for batches includes queued and running; "Waiting
  to start" only when `summary_counts` lacks `total`.
- `Processing.stage_throughput/1` and a provisional attempt-based
  `batch_progress/1` (replaced by member-based in Phase 3) with the ETA
  omission rules above.
- Every count labelled with its unit; Activity's "Processing" tile becomes
  per-stage.
- Verb renames per Vocabulary with subtitles; state-machine button labels
  replaced; Intake "Never fetched" for `not_modified`.
- `process_feed_response` withholds cache validators when any item failed
  (C5, first half — a bug fix in its own right).

Tests: throughput/ETA with a fake clock; batch summary with only queued
attempts; validators withheld after a partial failure; label assertions.

### Phase 2 — Step mutation contract, registry metadata, Pipeline tab

*Status: implemented 2026-09-14 in the working tree (uncommitted), ready for
audit. Delivered: registry `scope`/`prerequisites`/`requirements`/canonical
order with `position_for/1`; `create_step/2` (by step type), `update_step/2`,
`delete_step/1` enforcing prerequisites, dependents, rendering dependencies
(`Publishing.rendering_step_dependencies/1`), and active-work refusal;
`move_step/2` deleted; surviving item-step rows relinked on re-add;
position-normalization migration; `Processing.pipeline_overview/0` and
`addable_step_types/1`; `AdminLive.PipelineChain` components; Processing
`?tab=pipeline` with chain view, link menus (run existing / retry failed /
remove), add-step buttons, and the Start-batch picker; output-feed page
reduced to settings + read-only coverage line (and now surfaces changeset
errors on failed saves — previously silent); registry-driven list label.
Tests: `pipeline_steps_test.exs`, `processing_pipeline_test.exs`, migrated
output-feed assertions.*

- Registry: `scope`, `order`, `prerequisites`, `rendering_dependents`,
  labels. `create_step/2` derives `position`; `move_step/2` deleted; C4
  validation in `Processing`; LiveView duplicates removed. One-time
  `position` normalization migration (no-op on current data).
- `Processing.pipeline_overview/0` (one query pass) and the
  `pipeline_chain`/`chain_link` components; `/processing?tab=pipeline`.
- **Ships the Start-batch picker and the link-menu actions (Run on existing,
  Retry failed, Remove step) in this phase**, so removing the Output feed
  page's panels does not orphan any action (UI-09). Links to Attention are
  not emitted until Phase 3.
- Output feed page: panels and handlers removed; coverage line links to the
  Pipeline row; **Add matching articles** and **Refresh RSS output** stay.

Tests: C4 matrix via direct domain calls and LiveView (add/enable/disable/
remove × prerequisites × rendering settings × active work × re-add with old
items); chain order independent of row ids; picker excludes present and
unsatisfiable steps; migrated OutputFeed assertions.

### Phase 3 — Membership, cancellation, console, deletions

*Status: implemented 2026-09-14 in the working tree (uncommitted), ready for
audit. Delivered:*

- *C1/C2/C3/C7 (domain, from the earlier pass):* `pipeline_batch_members`,
  member-based `refresh_batch_run`, `cancel_feed_batch/1` with downstream
  cascade and dispatcher queue removal, conditional `mark_attempt_running`,
  `{:items, ids}` selection validated and snapshotted, eligibility checks in
  `start_feed_batch`.
- *C5 second half:* `Operations.resolve_failures/2` marks
  `raw_item_ingestion_failed` / `raw_item_processing_failed` /
  `generated_feed_item_create_failed` records resolved when the same entry
  later persists, processes, or publishes (matched on `related` keys; the
  check runs only when unresolved records of that type exist).
  `Pipeline.retry_entry_failure/1` replays the stored raw item through the
  same `process_raw_items` path (a `process_input_feed` run carrying
  `retry_of_failure_id`), or for ingestion failures refetches the feed with
  the new `fetch_input_feed(feed, trigger, ignore_validators: true)`. A
  record whose raw item or feed no longer exists is resolved and the retry
  returns an error naming why.
- *C6:* `Operations.start_run` records the owner pid in
  `debug_metadata["owner"]`; `run_owner_alive?/1`; `close_run_as_failed/1`
  is a conditional update that refuses a run that already finished. Scope:
  **operation runs only** (fetch, process, backfill, rerender) with a
  per-type stage timeout (2–15 min). Batches are excluded because their
  progress is member-based and `BatchDispatcher` already recovers them;
  attempts are excluded because the dispatchers monitor their tasks. Past
  the timeout a run is `:abandoned` (dead owner → **Close as failed**) or
  `:slow` (live owner → informational, no action).
- *Attention domain:* `Newspaper.Operations.Attention` derives groups —
  `step_failed` (step × failure kind × feed, action = `{:items, …}` retry
  batch; per-item Re-run uses the same action with one id), `site_backoff`
  (Try now), `feed_fetch_failed` (refetch without validators),
  `entry_failed` (replay), `stuck_run` (close). `count/0` counts groups with
  an action; it feeds the nav badge and the tab badge.
- *Console:* Processing has tabs Queue (home) / Batches / Attention /
  Pipeline / History. Queue: one stage card per registry step type
  (executions queued/running, trailing-window rate, ETA line omitted when
  paused or under-sampled, digestion model + **Pause/Resume**, extraction
  per-host list with pacing/backoff state and the single **Try now**),
  article-health line in canonical articles, Running now, Queued next per
  stage, Waiting, and a "Just finished" list linking to the Articles
  **Recently processed** sort. Batches: every batch across feeds running
  first, member-based progress, **Cancel**, the Start-batch picker (moved
  here; Pipeline links to it). Attention: groups with one action each and
  expandable items. History: all attempt statuses plus operations under the
  stage/feed/context filters (so article and batch context links are
  complete), and the failure records list with a Resolved badge. Legacy
  links that carry `stage`/`article_id`/`batch_run_id` without `tab` open
  History. One coalescer for every event plus a 30 s tick.
- *Deletions and moves:* `/` → Processing; `/sites` and `/runs` removed;
  `AdminLive.Dashboard` and `AdminLive.SiteExtractionPolicies` deleted with
  their tests migrated; website policies (config only), **Fetch all now**,
  and the latest-refresh line live on Sources (`/intake`, nav label
  "Sources"); Settings keeps fetch interval and Ollama only. Nav is five
  items with an attention badge on Processing. Dead helpers removed:
  `Operations.list_runs/list_run_entries/list_actionable_failure_groups`
  and their private helpers, `Content.list_recent_extracted_articles`,
  `Processing.list_recent_batches`.
- *Known compromise:* the nav badge on pages other than Processing is
  computed by `Nav.nav/1` on each render (a handful of small queries) rather
  than from a shared cache; Processing passes its own cached count.

*Tests: `attention_test.exs` (grouping and retry, abandoned vs slow runs,
close refusal after completion, replay resolution, refetch without
validators); `processing_test.exs`, `processing_batches_test.exs`,
`processing_attention_test.exs`, `intake_sites_test.exs`,
`navigation_test.exs` route matrix (every tab × legacy context × empty
database × deleted targets; the browser Back button is outside LiveViewTest),
`page_controller_test.exs`. Of the guardrail list below, **not written**:
cancel plus in-flight 429, restart before/after each C1/C2 boundary beyond
recovery of cancelled attempts, "missing generated item", the C6 cases for
paused batch / paced host / long model call (out of scope by the C6 scoping
above), and restart mid-group-enrollment. These are the first things an
audit should probe.*

- Migrations: `pipeline_batch_members`; `failures.resolved_at`; item-step
  status `cancelled`.
- C1, C2, C3 (cascading), C5 (second half), C6, C7.
- Tabs: Queue (home), Batches (member-based progress, Cancel), Attention
  (derived groups incl. unresolved pre-pipeline failures, liveness states),
  History (attempts, operations, failure records).
- Router: `/` → Processing; `/sites`, `/runs` removed; Dashboard and
  SiteExtractionPolicies deleted; site policies into Sources minus
  operational bits; pause and Try now relocated (single implementation).
- **Recently-processed discovery is preserved**: Articles gains a
  "Recently processed" sort (by latest artifact time) and the Queue page's
  recent-completions list links to it; the default publication-date sort is
  not treated as a replacement (UI-09).
- Route matrix test: every legacy and new link × tab × context × Back
  button × deleted target × empty database.

Tests: C1/C2 guardrails (cancel before/during enrollment, cancel vs claim,
stale enqueue, cancel plus in-flight 429, restart before/after each
boundary, repeated cancel, shared attempt across two batches, one owner
cancelled); C3 (cancelled extraction with pending digest; re-extraction not
reviving cancelled digestion; run-on-cancelled); C5 (bad entry then 304;
missing generated item; deleted target; resolution by later success only);
C6 (paused batch, paced host, long valid model call, orphan after restart,
close racing completion); C7 (restart mid-group-enrollment, foreign IDs,
stale IDs, double click).

### Phase 4 — Polish

*Status: implemented 2026-09-14 in the working tree (uncommitted), ready for
audit. Delivered: an expandable per-article History row on Articles that
loads that article's executions on first open (the step badges still deep
link to History context); empty states on every tab and list; the chain ⋯
menu is a native `details`/`summary` dropdown, so it is keyboard-operable
without focus management and there are no dialogs; tab bar and chains scroll
horizontally on narrow screens; dead helpers removed (listed under Phase 3).
Not done: a formal audit that every disabled control carries a reason beyond
the reasons enumerated in `PipelineChain`; no visual narrow-screen pass.*

Per-article history row; empty-state copy; disabled-reason coverage audit;
keyboard-accessible menus/dialogs and focus return; narrow-screen chains
and tabs; dead-helper cleanup.

### Audit reconciliation map

| Audit finding | Addressed by |
| --- | --- |
| UI-01 cancellation boundary | C2, Phase 3 |
| UI-02 batch membership | C1, Phase 3 |
| UI-03 cancel ≠ no-content | C3, Phase 3; cascade decided |
| UI-04 step mutation validation | C4, Phase 2 |
| UI-05 pre-pipeline failures | C5, Phases 1 and 3 |
| UI-06 liveness before close | C6, Phase 3 |
| UI-07 count units | Read-model contracts |
| UI-08 ETA/clock/events | Read-model contracts, Phase 1 |
| UI-09 phase gaps | Phase 2 ships picker/actions; recently-processed sort in Phase 3 |
| UI-10 registry boundary | Read-model contracts (last bullet) |
| UI-11 group retry scope | C7, Phase 3 |

## Decision log

Audit trail of product calls made by Ian, with the reasoning, so a cold
reader can see what was chosen and why. Nothing here is open.

### 2026-09-14 — framing

- **"Backfill" is banished.** Ian could not recall what it did months later;
  a verb an operator has to look up in code is a defect. Every operation
  gets a label stating its effect (Vocabulary table).
- **The pipeline UI is step-generic.** Two hardcoded actions per feed was
  never honest to the design — the registry and `pipeline_steps` are
  step-type-generic and filtering is planned. Verified further that
  execution is an ordered chain (`advance_item` halts at the first pending
  step), so the display is a chain per feed, not a column table.
- **V2 is a strict superset of today.** Feeds and delivery remain; V2 adds
  source-scoped enrichment. The Pipeline tab carries both scopes so V2
  Phase 2 moves a link, not a page.
- **The superset rule.** A new surface that is a strict superset of an old
  one replaces it; a mostly-superseded surface is merged or kept explicitly
  stripped, never left as a second slightly different view.

### 2026-09-14 — the five open calls

1. **Activity is deleted; Processing → Queue becomes the home page.**
   Reasoning: after removing what Queue/Attention/Batches supersede, Activity
   held only article tiles, recently-extracted, and latest fetch — too thin
   for the front-door slot. Tiles become a summary line on Queue;
   recently-extracted is Articles' default sort; fetch status moves to the
   Sources header beside Fetch all now.
2. **Cancel batch is in scope.** Reasoning: it is the missing half of
   "start batch"; today the only way to stop a regretted 2,800-item retry is
   a global pause or waiting it out. Semantics: remaining queued attempts
   become skipped, the run closes, completed work stays.
3. **Attention is a tab inside Processing** (not a top-level nav item).
   Reasoning: keeps all operations under one roof and nav at five items. The
   Processing nav item may carry the attention count as a badge so it is
   visible from every page.
4. **Chain links use a ⋯ menu, not inline buttons.** Reasoning: the chain's
   readability is the point of the view; inline buttons crowd it past three
   steps.
5. **Steps cannot be reordered.** Reasoning: order should not be a per-feed
   choice; the Pipeline tab is the single configuration surface (enable /
   add / remove) and order is canonical from the registry. Consequence:
   `move_step` is deleted, `position` is derived, the deadlock ordering
   becomes impossible. (Ian asked whether pipeline config "exists elsewhere";
   it does not — after this plan the only other source of pipeline
   configuration is the code registry.)

### 2026-09-14 — after audit `01-ui-processing-plan.md`

- **Scope corrected from presentation-only to presentation plus three
  lifecycle contracts** (cancellation, batch membership, step-mutation
  validation). Reasoning: the audit showed with code evidence that attempts
  are shared across feeds, claiming is unconditional, and step mutation has
  no domain-side validation; a UI over those gaps would mislead. Accepted in
  full; every finding is mapped in the reconciliation table.
- **UI-03 decided: cancellation cascades downstream.** Cancelling a batch
  of step X also cancels the not-yet-started downstream steps that were
  requested for the same items. Reasoning (Ian): partially-cancelled chains
  are a confusing intermediate state; the right safety valve is making
  re-queue trivial, not leaving downstream demand dangling. Consequence:
  "Run on cancelled items" re-creates the whole cancelled chain segment, so
  cancel/re-queue is a reversible pair. (Astra and Fable had recommended the
  narrower option; overruled — the reversibility argument is stronger.)
- **Commit policy for this redesign (Ian):** nothing is committed until the
  whole redesign is done; work accumulates in the tree. AGENTS.md's
  commit/push/deploy-by-default rule is suspended for this effort.
