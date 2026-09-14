# Processing UI Plan Audit

Scope: `planning/ui-processing-redesign.md`, checked against the current
Processing, Publishing, Operations, dispatcher, schema, and LiveView code.
This is a plan audit, not authorization to implement the redesign. Ian's
chosen page layout, canonical step ordering, and inclusion of cancellation
remain the product direction. Fable owns plan reconciliation and implementation.
Findings describe gaps in the proposed contracts, including interactions with
existing behavior; they are not claims that unimplemented controls already fail.
Line references target the current working-copy plan and code, not a deployed
redesign.

Evidence paths: domain module basenames refer to `newspaper/lib/newspaper/`;
`output_feed.ex` refers to
`newspaper/lib/newspaper_web/live/admin_live/output_feed.ex`. Schema and
dispatcher modules live below `newspaper/lib/newspaper/processing/`, with
digestion's dispatcher below `newspaper/lib/newspaper/digestion/`.

Use stable `UI-NN` IDs. Remove findings after the plan supplies the missing
contract; do not mark them completed. Any `DECISION-NEEDED` item is a narrowly
identified product question, not a request to reopen the overall redesign.

## Review Coverage

| Area | Review scope |
| --- | --- |
| Cancellation and batch ownership | Domain and dispatcher call paths |
| Pipeline configuration | Definition and item snapshots; validation paths |
| Attention and recovery | Failure creation, fetch cache validators, run lifecycle |
| Counts, ETA, navigation, rollout | Read models, events, list ordering, phase dependencies |

## Findings

### UI-01: Cancellation needs a durable execution boundary

- Severity: High. Type: missing lifecycle contract. Effort: medium/large.
- Plan: lines 410-415; the read-only-domain invariant at 279-293.
- Evidence: `processing.ex:116` checks batch status once before enrollment;
  `processing.ex:1051` then enrolls the whole list without checking it again.
  `digestion.ex:97` and `extraction.ex:22` start attempts without a conditional
  queued-to-running claim. `processing.ex:1033` can reopen a finished run
  whenever active attempts exist. `processing.ex:833` schedules rate-limit
  retries without a cancellation check.
- Problem: setting currently queued rows to skipped and removing in-memory
  queue entries does not stop enrollment already underway, a dispatcher that
  already popped an ID, late enqueue messages, or the retry created by an
  in-flight extraction. Sending GenServer messages inside a SQL transaction
  does not make their effects transactional. Recovery can revive more work.
- Decision: make cancellation durable and consult it during enrollment,
  attempt claiming, retry creation, and recovery. Commit database state before
  notifying dispatchers; dispatchers must reject stale/cancelled work even if
  queue cleanup is delayed. Completion must preserve cancellation intent while
  allowing already-running attempts to finish. Explicitly permit these
  domain changes in the plan instead of promising read-only changes.
- Guardrails: cancellation before/during enrollment; cancel versus claim;
  stale enqueue after cancel; cancel plus an in-flight 429; restart before and
  after each boundary; repeated cancel; transaction rollback. Cover both
  dispatchers, `processing_batch_test.exs`, and `processing_recovery_test.exs`
  if a dedicated recovery test module is introduced.

### UI-02: Batch membership is not exclusive ownership of an attempt

- Severity: High. Type: scope and progress correctness. Effort: medium/large.
- Plan: lines 150-153, 316-320, 410-415, 421-424.
- Evidence: `processing.ex:1125` reuses any active attempt for the same
  article/step and attaches another item step to it. The attempt has only one
  `batch_run_id`. `refresh_batch_run/2` counts only that foreign key, and
  `retry_attempt/2` creates retry attempts without forwarding batch ownership.
- Problem: two feeds can share one attempt. A batch that joins an existing
  attempt can report no active work of its own; cancelling the original
  batch's attempt can skip the other feed's work. Automatic extraction retries
  can leave the original batch while remaining queued. Regrouping by batch
  cannot provide correct progress or cancellation from this foreign key alone.
- Decision: define durable membership of requested item steps in a batch,
  separately from execution-attempt ownership. Derive batch progress from
  those members and their batch-scoped outcomes, retaining terminal outcomes
  when the same item is rerun in a later batch. Cancelling one batch withdraws
  its demand; shared attempts continue for remaining demand. Preserve current
  attempt deduplication and foreground priority. Keep retry lineage explicit.
- Guardrails: two feeds sharing an article; a bulk request joining foreground
  work; concurrent starts; retries after 429; cancellation of only one owner;
  progress and ETA following the surviving work. Never label a shared queued
  attempt as already skipped or completed.

### UI-03: User cancellation must be distinguishable from no-content skips

- Severity: High. Type: missing recovery semantics. Effort: medium.
- Plan: lines 65-67, 152-153, 411-414.
- Evidence: `processing.ex:372` advances past skipped steps;
  `processing.ex:1372` reactivates all skipped digestion steps after successful
  extraction. Existing batch selections cover only not-requested and failed.
- Problem: a cancelled extraction is not evidence that the article has no
  content. Reusing the same skip semantics may unblock downstream work, revive
  cancelled digestion on re-extraction, or leave thousands of cancelled items
  unreachable through either bulk-start action.
- Decision: preserve a machine-readable cancellation reason distinct from
  content ineligibility, even if the operator-facing word remains Skipped.
  Define how downstream demand behaves and provide an explicit bulk path to
  request the cancelled remainder again. Automatic content-based reactivation
  must not treat operator cancellation as no-content recovery.
- DECISION-NEEDED: confirm whether cancelling a batch withdraws only that
  step's batch request or also its automatically requested downstream work.
  Recommendation: withdraw that batch's demand only, and expose continuing
  shared/downstream work in the cancellation result.
- Guardrails: extraction cancellation with a pending digest; digest
  cancellation followed by re-extraction; cancelled items with an older valid
  artifact; bulk re-request without rerunning completed members.

### UI-04: Moving and expanding pipeline controls needs domain validation

- Severity: High. Type: missing mutation guardrails. Effort: medium.
- Plan: lines 199-205, 348-378, auditor question 4.
- Evidence: `output_feed.ex:672` protects disable operations using both
  prerequisites and rendering settings. `Processing.update_step/2` and
  `delete_step/1` do not perform those checks. Publishing's dependency
  validation protects feed edits, not independent step mutations.
  `list_item_steps/1` and `advance_item/2` execute persisted item-step positions,
  not only current `pipeline_steps.position`; item steps survive definition
  deletion through a nullable foreign key.
- Problem: the plan explicitly moves create/remove prerequisite checks but
  omits disabling prerequisites and removing/disabling a step used for digest
  titles, digest bodies, extracted bodies, or hosted links. Normalizing only
  definition positions does not normalize existing executable item chains.
  Removing and re-adding a definition can leave old snapshot state whose
  execution and display no longer match the visible chain.
- Decision: centralize add/enable/disable/remove validation in Processing,
  including rendering dependencies. Preserve future-only changes and existing
  artifact selections; specify removal with queued/running work, historical
  item rows, and re-addition. Normalize or deliberately preserve both position
  layers under the snapshot policy; never silently rewrite existing requests.
- Guardrails: direct domain calls as well as LiveView tests; disable/remove a
  prerequisite; remove the only digest step while digest rendering is selected;
  two tabs editing concurrently; remove/re-add with old items and active work;
  old item positions differing from the current definition. Keep feed GUIDs
  and selected artifact references stable.

### UI-05: Derived Attention loses failures before item-step creation

- Severity: High. Type: missing recovery coverage. Effort: medium.
- Plan: lines 416-426, 438-439, auditor question 1.
- Evidence: `pipeline.ex:248-319` records `raw_item_ingestion_failed`,
  `raw_item_processing_failed`, and `generated_feed_item_create_failed`.
  Failed ingestion can have no RawItem, and failed publication can have no
  generated item. `process_feed_response/3` saves HTTP cache validators even
  when processing individual entries failed; the 304 branch then marks the
  feed `not_modified` without replaying those entries. Re-render errors are
  also recorded on an operation run, not necessarily an item step.
- Problem: `last_fetch_status = failed` can briefly represent these errors,
  but a subsequent successful/unchanged fetch erases the signal without
  repairing missing data. Merely refetching may receive 304; an older entry
  may also have disappeared from the current source feed. Moving every
  failure record to History leaves no actionable current representation.
- Decision: give pre-pipeline and publication failures a durable unresolved
  projection with explicit resolution evidence. This can refer to historical
  failures; it need not create a second mutable inbox. Derive resolution from
  successful processing of the affected entry/output, not simply the latest
  fetch status. Replay stored raw data when available; an unavailable raw
  entry needs an explicit fresh-fetch recovery path and an honest limitation
  if the publisher no longer provides it. Preserve diagnostic links for
  non-retryable failures instead of offering a misleading Retry button.
- Guardrails: one bad entry in an otherwise good fetch followed by 304;
  raw processing failure with stored data; missing generated item; rendering
  operation failure; deleted target; recovery outside the current feed window.
  Historical failures alone must not keep resolved Attention groups alive.

### UI-06: A quiet running operation is not necessarily abandoned

- Severity: High. Type: unsafe recovery action. Effort: medium.
- Plan: lines 168-169, 419-425.
- Evidence: `Operations.fail_interrupted_operation_runs/0` marks diagnostic
  operation rows failed after restart; it neither stops a live task nor
  changes attempt state. Batch runs are deliberately excluded. Fetch and
  re-render operations do not create pipeline attempts for their work.
- Problem: absence of attempt activity cannot distinguish a stuck operation
  from fetching, enrollment, an Ollama request, a paused queue, a host waiting
  on backoff, or bulk work waiting behind foreground requests. Applying the
  startup cleanup to a live run can report failure while it still writes data,
  and its later completion can overwrite that report.
- Decision: separate expected waiting, suspected slowness, and proven
  abandonment. Show reasons and relevant timestamps for the first two.
  Only offer Close as failed when ownership/liveness evidence establishes
  abandonment and the transition cannot race a legitimate completion. Use
  stage-appropriate timeouts and lifecycle checks, not one global age cutoff.
- Guardrails: paused digest batch; paced extraction; long but valid model
  request; foreground starvation; fetch/re-render with no attempts; orphan
  after restart; completion racing the close action. A diagnostic close must
  not be presented as cancellation or as repair of queued work.

### UI-07: Shared vocabulary does not make the counted entities equivalent

- Severity: Medium. Type: read-model and operator interpretation. Effort: medium.
- Plan: lines 65-70, 137-145, 190-197, 321-323.
- Evidence: `Content.article_status_counts/0` counts canonical Articles;
  `Processing.feed_step_counts/2` counts output item steps;
  `processing_attempt_counts/1` counts execution attempts. The active-attempt
  deduplication in UI-02 makes these intentionally different. Publishing's
  `publication_status/2` withholds items needing a digest, while extracted
  content and hosted links can fall back to the original source.
- Problem: relabelling all statuses cannot reconcile these totals. A feed
  chain's failed extraction count does not imply all digestion is blocked:
  different articles occupy different stages simultaneously. An extraction
  marked Ready does not mean an item is published, nor that RSS contains the
  desired rendered content. Waiting also currently combines pending demand
  with bookkeeping rows that have never been explicitly requested.
- Decision: specify each display's unit and filter scope: unique executions
  for Queue, requested members for Batches, output item steps for Pipeline,
  canonical articles for the library. Make aggregate-to-detail links use the
  same selection predicate. Keep the seven state labels, but include waiting
  reasons and request intent. Treat chain arrows as dependency order, not a
  whole-feed barrier. Add a feed-level publication/held count and drill-down
  reason alongside processing coverage; do not change rendering policy here.
- Guardrails: a shared article in two feeds; mixed ready/failed/queued items
  in one chain; digestion never requested versus requested but blocked;
  no-content skip with digest rendering; valid old artifact during rerun;
  held output with no failed step; filters applied consistently across views.

### UI-08: ETA and live Attention need explicit clock and event contracts

- Severity: Medium. Type: misleading estimates and stale UI. Effort: medium.
- Plan: lines 68-70, 316-320, 400-407, 443-445.
- Evidence: foreground and bulk queues have different priority;
  extraction is paced independently by host, digestion is globally serial
  and pausable. Attempt completion is not always completion of requested
  batch demand (UI-02). Current Processing handles settings, site policies,
  publishing, and operations events as well as `:processing_changed`.
- Problem: dividing queued rows by trailing completions yields a countdown
  for work that may be paused, waiting on a prerequisite, retrying, or behind
  another queue. Instant artifact reuse and cancelled rows inflate throughput.
  Refreshing the nav badge only on processing events misses feed failures and
  settings/policy changes; expiry of a backoff or throughput window need not
  emit any event at all.
- Decision: define rate as execution throughput and ETA as an explicitly
  approximate estimate for eligible remaining work. Keep paused/blocked/
  backoff states visible and omit ETA when the estimate is not defensible.
  Exclude cancellations and artifact reuse from service throughput. Refresh
  projections on all contributing domain events plus a bounded server-side
  clock tick/next-deadline refresh for time-derived state. Coalesce the combined
  event stream, and fetch only the active tab's bounded detail lists.
- Guardrails: fake-clock window/expiry tests; startup with no samples; restart;
  pause/resume; multiple hosts at different rates; retry without member
  completion; large artifact reuse; settings-only and feed-only updates;
  burst events across several open pages. No custom page-content JavaScript
  is needed for these behaviors.

### UI-09: The proposed phases have control and discovery gaps

- Severity: Medium. Type: rollout regression. Effort: small/medium.
- Plan: lines 122, 290-298, 360-369, 408-410, 448-451.
- Evidence: Phase 2 removes output-page batch handlers and links to Attention,
  while the shared Start batch picker and Attention tab ship in Phase 3.
  `Content.list_articles_page/1` orders by publication date, whereas
  `list_recent_extracted_articles/1` orders by extraction time.
- Problem: the phases cannot be independently shipped as written without
  temporary direct handlers or the picker moving earlier. An Articles link
  with today's default sorting does not replace Recently extracted: an old
  article just extracted is buried again, recreating the original complaint.
  Preserving only the route string is insufficient if its context is ignored
  by the default tab or paging controls.
- Decision: ship the picker/working step actions with Phase 2 and defer
  Attention links until that tab exists, or explicitly ship Phases 2 and 3
  together. Preserve a recently-processed discovery path through an Articles
  sort/filter or a working recent-completions link. Define a route matrix for
  legacy and new article/batch/feed/stage links, tab switches, browser Back,
  and the relevant row/filter focus. Run it at each deploy boundary.
- Guardrails: every old action reachable after Phase 2; old article extracted
  today discoverable immediately; deep links with and without explicit tabs;
  filters surviving pagination; unavailable/deleted targets; empty databases.

### UI-10: Registry metadata is not a generic execution contract

- Severity: Medium. Type: scope boundary and future coupling. Effort: medium.
- Plan: lines 60-64, 207-213, 348-356; auditor questions 2 and 5.
- Evidence: runtime dispatch, artifact reuse, config snapshots, and readiness
  are specialized by step type in `processing.ex`. Digestion currently needs
  an actual `ArticleExtraction`, not merely a preceding step that terminated.
  The registry distinguishes an operation type from its implementation key.
  `planning/newspaper/domain-model.md:208-236` puts enrichment upstream of
  outputs, including sources with no output feed membership.
- Problem: a prerequisite list and an enum-like scope field alone cannot
  make a new operation executable. Treating a skipped prerequisite as ready
  would change digestion eligibility. Moving extraction upstream later changes
  ownership, request creation, counts, and cancellation, not just row placement.
  A source chain per Input Feed could duplicate one per Outlet/article.
- Decision: keep this change to registry-driven presentation/configuration
  for the two existing operations, with explicit typed readiness/artifact
  handling preserved. Preserve the type-versus-implementation distinction.
  Do not put unimplemented operations in the picker or build a universal
  pipeline engine for this redesign. Identify the current target scope in
  read models without baking feed IDs into generic component interfaces;
  leave upstream ownership and filtering to their planned domain migration.
  Replace the promise that "nothing else changes" with that explicit boundary.
- Guardrails: no-content extraction does not become eligible digestion;
  registered-but-unexecutable steps cannot be selected; existing model and
  artifact snapshots still determine reuse; output chains remain correct
  without fabricating source chains or prematurely assigning filtering scope.

### UI-11: Group retry must preserve both selection and action scope

- Severity: Medium. Type: targeted mutation contract. Effort: medium.
- Plan: lines 166, 421-426.
- Evidence: current `start_feed_batch/4` stores a selection mode in run
  metadata and selects matching items during enrollment/recovery. The proposed
  `{:failed, item_ids}` selection is new. `enqueue_article_step/3` enumerates
  all generated items for that article, not just the Attention group's feed.
  Existing output-page handlers also guard starts when a matching batch is
  active or digestion settings make a request unavailable.
- Problem: dropping the ID subset on restart silently turns a group retry
  into a whole-feed retry. Trusting browser-provided IDs can act outside the
  selected group, and a feed-scoped per-item action that calls the existing
  article-wide API may rerun other feeds as well. Moving controls can lose
  their eligibility guards or make double clicks enroll duplicate batches.
- Decision: snapshot the requested membership durably, validate feed/type/
  current failure eligibility server-side, and retain that scope through
  enrollment and recovery. Use item-scoped retry for item-scoped controls;
  article-wide reruns belong to explicitly article-wide actions. Move request
  eligibility and active-batch checks out of page-specific handlers, with
  clear disabled reasons and idempotent behavior under concurrent clicks.
- Guardrails: restart midway through group enrollment; IDs from another feed;
  failures resolved since rendering; an article shared with an unaffected
  output; simultaneous start clicks; pause/unconfigured model/disabled step;
  no eligible members left. Historical failed attempts remain immutable.

## Explicitly Fine / Leave Alone

- Processing as the home page, the five tabs, consolidation of controls,
  and Sources owning website configuration are coherent product choices.
- Canonical order is an intentional simplification, not a missing drag-and-drop
  feature. Do not reopen ordering or the page layout during implementation.
- Derived current Attention and immutable diagnostic History are the right
  distinction. UI-05 asks for coverage and resolution evidence, not a generic
  ticketing system or a second source of execution state.
- Per-article history, generation/rendering separation, foreground priority,
  site-level extraction policy, and the existing escalation ladder should be
  preserved. No scheduler replacement or security work is required by this audit.
- Reuse Phoenix LiveView, streams, and native loading feedback. Acceptance
  checks should include keyboard-accessible menus/dialogs, focus after closing
  a dialog, outside-click dismissal, narrow-screen chains/tabs, and disabled
  reasons available without hover; do not add a custom client state layer.

## Suggested Reconciliation Order

1. Establish the cancellation, batch membership, and prerequisite mutation
   contracts (UI-01 through UI-04). These define required domain changes and
   correct the presentation-only scope claim.
2. Specify Attention resolution and safe intervention (UI-05, UI-06, UI-11).
3. Align projections, estimates, and phase boundaries (UI-07 through UI-10).
   The immediate label fixes can still ship independently.

The only product question identified here is UI-03's downstream cancellation
scope. The remaining findings can be reconciled as engineering contracts
without reopening Ian's chosen information architecture.

## Test Locations for Implementation

- Lifecycle, membership, cancellation, and retry: extend
  `newspaper/test/newspaper/processing_batch_test.exs`,
  `processing_dispatcher_test.exs`, `processing_priority_test.exs`, and
  `digestion_pipeline_test.exs` in that directory.
- Pre-pipeline recovery and publication: extend
  `newspaper/test/newspaper/pipeline_fetch_test.exs`,
  `pipeline_output_feed_test.exs`, and `operations_recovery_test.exs`.
- Mutation and navigation behavior: migrate assertions from
  `newspaper/test/newspaper_web/live/admin_live/output_feed_test.exs`,
  `dashboard_test.exs`, `settings_test.exs`, and
  `site_extraction_policies_test.exs` into `processing_test.exs` or focused
  replacement modules. Extend `navigation_test.exs` and
  `articles_discovery_test.exs` for deep links and recent processing.
- Reproduce any exposed existing bug with a failing test before its fix.
  New control behaviors should have focused tests before implementation;
  use the full suite and production smoke checks at each deployment boundary.
