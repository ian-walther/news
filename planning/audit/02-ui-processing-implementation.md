# Processing Redesign Implementation Audit

Scope: Fable's working-tree implementation of `planning/ui-processing-redesign.md`
and its C1-C7 contracts, compared with base commit `5c4363d`. This review includes
untracked implementation files and staged deletions. It does not authorize
implementation changes, commits, or deployment. Preserve the redesign's explicit
commit hold while findings are reconciled.

Use stable `IMP-NN` finding IDs. Each finding records evidence, user impact, an
implementation decision, and regression-test requirements. Remove resolved
findings after verification; do not replace them with completion notes. Ian's
decision that cancellation cascades downstream is authoritative.

## Review Coverage

| Area | Evidence and limits |
| --- | --- |
| Batch membership, enrollment, cancellation, restart | Domain/dispatcher traces and focused shared-consumer probes; concurrent crash-barrier tests remain required |
| Step mutation, snapshots, artifact reuse, publication | Mutation validation and reuse paths; migration SQL selection reproduced against shared work; no production migration rehearsal |
| Attention, replay, resolution, liveness | Origin-to-recovery traces and actual feed/recovery probes |
| Queue, Batches, Pipeline, History, navigation | Query/state review and LiveView link, ordering, count, and refresh probes |
| Sources, Articles, Settings, removed screens | Route and functional-parity diff, moved controls, expanded-history and navigation tests |
| Browser behavior | Isolated loopback preview with rollback-only test fixtures; native menu and rejected-toggle behavior; no responsive visual signoff because current CSS build is blocked locally |

## Release Recommendation

Do not deploy this working tree before resolving the shared-demand lifecycle
findings (IMP-01 through IMP-06), GUID-less ingestion crash (IMP-09), and upgrade
membership corruption (IMP-20). IMP-08 is the required user-facing recovery
counterpart to cancellation. Fix these as coherent lifecycle work, not unrelated
UI patches: several symptoms share the same missing distinction between request,
execution, and historical outcome.

The normal suite can stay green while these paths are broken. The audit adds
17 deliberately failing probes outside the normal test tree; 17/17 reproduce
the stated failures. Browser reproductions cover IMP-14 and IMP-22. Remaining
findings identify directly traced gaps/scaling risks, with specific tests still
needed before fixes can be accepted. Do not describe those as load-tested or
crash-rehearsed behavior.

## Findings

### IMP-01: Shared attempt completion leaves other batches running indefinitely

- Severity: High. Contract: C1. Effort: small/medium.
- Location: `newspaper/lib/newspaper/processing.ex:2175` and `:2086`.
- Evidence: an execution updates outcomes for every referencing member, but
  `refresh_attempt_batch/1` refreshes only `attempt.batch_run_id`. Start batches
  in two feeds sharing one article, finish their single execution, and the
  second batch remains `running`. The audit probe fails with that exact state.
- Impact: progress stays stale and `ensure_no_running_batch/2` blocks another
  batch for that feed/step. A UI refresh does not repair the persisted run.
- Decision: refresh all affected batch IDs from durable membership whenever
  an item-step outcome/state changes, including cancellation, artifact reuse,
  recovery, and dependency-driven skips. Do not use attempt ownership as the
  complete set of consumers.
- Tests: both feeds' batches close; foreground-owned shared attempt; bulk
  reuses a completed artifact; cascading cancellation settles downstream
  batches; no terminal historical batch is reopened by later independent work.

### IMP-02: Retryable execution failures prematurely finalize batch members

- Severity: High. Contract: C1 and preserved automatic retry behavior.
  Effort: medium.
- Location: `newspaper/lib/newspaper/processing.ex:2086`, `:1395`, `:1597`.
- Evidence: `finish_attempt(..., "failed")` permanently sets member outcome
  `failed` before `schedule_automatic_retry/1` creates a queued retry.
  `retry_attempt/2` now retains the batch ID, but does not reopen its member.
  The probe confirms the retry is queued while its batch is already failed.
- Impact: Batches/ETA/Cancellation no longer describe ongoing retries; another
  batch can start despite work still running, and eventual success leaves the
  original batch failed. Retaining the foreign key alone did not preserve
  batch lineage semantics.
- Decision: distinguish individual attempt outcomes from the terminal outcome
  of a requested batch member. Keep a member active through permitted automatic
  retries; finalize only when its demand succeeds, is skipped/cancelled, or
  exhausts the retry policy. Explicit later retries must create new demand
  without modifying old terminal membership.
- Tests: 429 then queued retry then success; exhausted retry budget; cancel
  between failed attempt and retry; restart at each retry boundary; immutable
  historical failed attempts and prior independently completed batches.

### IMP-03: Shared execution updates resurrect cancelled item steps

- Severity: High. Contracts: C2/C3. Effort: medium.
- Location: `newspaper/lib/newspaper/processing.ex:2086`, `:1453`, `:1562`.
- Evidence: cancelling one feed correctly leaves a shared attempt queued for
  the other feed, but `update_attempt_item_steps/2` updates every row retaining
  that attempt ID, including the cancelled row. The probe observes Cancelled
  becoming Running as soon as the surviving execution is claimed. Artifact
  attachment and completion use the same helper. `skip_article_steps/3` also
  explicitly includes `cancelled`, undoing the no-content distinction.
- Impact: withdrawn work appears to resume, cancelled items can acquire new
  artifacts, and no-content followed by a later extraction can reactivate
  demand that the user deliberately cancelled.
- Decision: propagate execution state/artifacts only to live demand attached
  to that execution; preserve cancelled item status and its historical links.
  Exclude operator cancellation from content-ineligibility conversion and
  automatic reactivation. Keep explicit Run on cancelled items as the only
  bulk reversal of that intent.
- Tests: shared claim, success, failure, artifact attachment, and no-content
  must all preserve the cancelled feed's state while updating the survivor.

### IMP-04: Cancellation does not cascade below a running batch member

- Severity: High. Contract: C3, Ian's explicit downstream-cascade decision.
  Effort: small/medium.
- Location: `newspaper/lib/newspaper/processing.ex:245` and `:313`.
- Evidence: downstream selection starts only from members whose own item step
  is cancellable. A running extraction is excluded, so its blocked digestion
  is excluded too. The probe leaves digestion Blocked after batch cancellation;
  successful extraction can subsequently start it normally.
- Impact: the batch cancellation's promise to withdraw unstarted downstream
  work is false for the article currently running. A completed upstream member
  with unfinished downstream demand has the same selection problem.
- Decision: choose downstream candidates from the batch's requested members,
  independently of whether each upstream member can itself be stopped.
  Preserve running/completed upstream work, but withdraw eligible downstream
  demand and report those counts. Apply shared-demand protection separately.
- Tests: upstream queued, running, and completed with downstream blocked or
  queued; downstream already running; independently demanded shared work;
  one-action reversal re-requests exactly the cancelled chain segment.

### IMP-05: Recovery and retries treat the originating batch as sole owner

- Severity: High. Contracts: C1/C2. Effort: medium.
- Location: `newspaper/lib/newspaper/processing.ex:1289`, `:1423`, `:1395`.
- Evidence: recovery skips running attempts solely because their original
  batch contains `cancelled_at`, then cancels all associated item steps.
  The probe cancels batch A while A/B share running work: recovery returns
  zero requeued attempts instead of retaining B's demand. Automatic retry has
  the same original-batch-only suppression; manual `retry_attempt/2` has no
  cancelled-demand guard at all.
- Impact: restarting can cancel unrelated surviving feeds; a 429 can prevent
  those feeds from receiving retries even without a restart. Conversely a
  direct retry can recreate work under a cancelled batch.
- Decision: base claim/retry/recovery eligibility on current live demand, not
  the original batch pointer. Preserve surviving member/foreground demand and
  its priority; withdraw only cancelled demand. Settle all affected batch
  members when recovery drops an abandoned execution.
- Tests: cancelled origin plus surviving batch or foreground consumer; shared
  in-flight 429; restart of both dispatchers; no surviving demand; explicit
  retry of a cancelled execution without a new request.

### IMP-06: Enrollment is neither atomic with cancellation nor restart-complete

- Severity: High. Contracts: C1/C2/C7. Effort: medium/large.
- Location: `newspaper/lib/newspaper/processing.ex:87`, `:161`, `:1690`,
  `:1716`, `:1747`, and `:1453`.
- Evidence: normal batches create members *after* requesting/dispatching each
  item. Explicit subsets insert members individually after creating the run,
  outside a transaction. Enrollment checks cancellation only every 20 items;
  `request_item_step/3` and the queued-to-running claim do not check batch
  demand under the same lock. The late-enrollment probe creates a new queued
  attempt after cancellation. Recovery selects existing unfinished members,
  so a partially enrolled batch can omit its never-enrolled remainder; an
  all-terminal partial prefix can instead cause it to select a fresh set.
- Impact: Cancel can return before more work is created; crashes lose intended
  membership or expand a request; a fast execution can close a partially
  enrolled batch before membership exists. Active-batch deduplication is also
  a read-then-insert check with no database serialization.
- Decision: atomically persist the complete intended selection and enrollment
  state before dispatch, and serialize cancellation/claim/enrollment against
  that durable demand. Dispatch only after commit; queue cleanup is advisory.
  Reject stale enrollment and preserve the exact selection through recovery.
  Enforce one active request per feed/step using a transactional boundary.
- Tests: barriers at selection/run/member/attempt/claim boundaries; restart
  after a prefix; cancel versus claim; fast execution during enrollment;
  concurrent starts. Extend the simple late-request probe into deterministic
  dispatcher/enrollment interleaving tests before fixing the code.

### IMP-07: Step removal misses queued work owned by another feed

- Severity: Medium. Contract: C4. Effort: small/medium.
- Location: `newspaper/lib/newspaper/processing.ex:932`.
- Evidence: `ensure_no_active_work/1` checks `attempt.pipeline_step_id`, which
  refers to the first consumer's definition. The shared-feed probe deletes
  feed B's definition successfully while B's item step is queued on feed A's
  attempt. B still has executable snapshot state after the UI removes it.
- Decision: validate active demand through the definition's item steps and
  batch members, including shared attempts and pending enrollment. Serialize
  this guard with new demand so removal cannot race enrollment.
- Tests: shared queued/running attempt from another feed, blocked/pending
  requested work, cancellation followed by removal, and concurrent start/delete.

### IMP-08: Cancelled work has no bulk recovery control or complete coverage count

- Severity: High. Contract: C3's required one-action reversal. Effort: small.
- Location: `newspaper/lib/newspaper_web/live/admin_live/processing.ex:120`
  and `:1637`; `pipeline_chain.ex:100`; `newspaper/lib/newspaper/processing.ex:412`.
- Evidence: the batch selection handler and picker recognize only failed and
  not-requested items; the chain menu contains only Run existing, Retry failed,
  and Remove. The UI probe cannot find a cancelled-item option. Domain coverage
  counts also omit `cancelled` and `pending` despite including them in total.
- Impact: after cancelling a large batch, neither bulk action selects those
  items. A chain can show zero ready, no actionable remaining count, and a
  green Ready tone. The domain-only `:cancelled` API is not a user-facing
  safety valve.
- Decision: expose Run on cancelled items in the shared picker and step menu,
  map it to `:cancelled`, and show cancelled/pending counts with truthful
  readiness/intent. Include per-step cascade counts in cancellation feedback.
- Tests: cancel via LiveView, see exact remaining selection, requeue through
  the UI once, and verify downstream demand is restored without redoing ready
  members. Counts must partition the represented output item steps.

### IMP-09: Failure resolution crashes valid feeds that omit GUIDs

- Severity: High. Contract: C5. Effort: small.
- Location: `newspaper/lib/newspaper/pipeline.ex:331` and
  `newspaper/lib/newspaper/operations.ex:181`.
- Evidence: the parser permits `feed_guid: nil`, but the new ingestion-success
  path always resolves by `{"feed_guid", raw_item.feed_guid}`. The resolver
  accepts only integer/string values. An unresolved ingestion failure anywhere
  enables this path for every fetched feed; a valid URL-only RSS item then
  raises `FunctionClauseError` outside the raw-item processing rescue.
- Impact: one bad historical entry can break ingestion of unrelated valid
  feeds and abort the remainder of a global fetch cycle. The audit's GUID-less
  RSS probe reproduces the exception.
- Decision: use the documented feed-scoped stable-ID-or-URL matching contract,
  rejecting empty criteria rather than dropping them into a broad update.
  Handle absent identifiers explicitly and keep diagnostic reconciliation
  from crashing successful ingestion.
- Tests: GUID-less RSS, ID-less Atom where supported, URL fallback, no usable
  identifier, identical URLs/GUIDs in different feeds, and an unresolved error
  in another source. Only the actual repaired entry's failure may resolve.

### IMP-10: Closing an abandoned run does not validate abandonment

- Severity: Medium. Contract: C6. Effort: medium.
- Location: `newspaper/lib/newspaper/operations.ex:129` and `:146`.
- Evidence: `close_run_as_failed/1` checks only `status == running`. The audit
  probe successfully closes a run whose owner is demonstrably alive. It also
  accepts pipeline run IDs even though the UI's narrowed policy excludes them.
  Persisting `inspect(self())` does not encode the VM boot identity; parsing
  the string after restart cannot establish that it is the original owner.
- Decision: enforce run kind, liveness/ownership, timeout, and the conditional
  transition in the domain action, not only in the Attention projection.
  Record boot-scoped execution identity or another verifiable ownership token.
  Reject stale actions with a useful result instead of changing healthy work.
- Tests: live owner; wrong run kind; stale displayed action; process exit;
  previous-boot PID text colliding with a current PID; legitimate completion
  racing the action. Narrowing the action to operation runs is otherwise fine.

### IMP-11: Queue tab links route back to History when context is present

- Severity: Medium. Contract: route matrix and usable tab navigation.
  Effort: small.
- Location: `newspaper/lib/newspaper_web/live/admin_live/processing.ex:51`
  and `:1645`.
- Evidence: `processing_path/1` omits `tab=queue`; `handle_params/3` interprets
  a missing tab plus stage/article/batch context as History. Clicking Queue
  from stage-filtered History therefore renders History again. Reproduced
  through the actual LiveView tab link, not a synthesized route.
- Decision: encode an explicit Queue choice and define how each tab preserves,
  applies, or clears context. Keep the legacy missing-tab interpretation only
  for legacy entry links. Make active filters visible and clearable outside
  History as well; do not carry invisible filters into later tabs.
- Tests: actual clicks from every contextual tab to Queue, Back/Forward,
  article and batch deep links, and switching between feed-filtered tabs.

### IMP-12: Background updates erase expanded article history

- Severity: Medium. Contract: useful live per-article history. Effort: small.
- Location: `newspaper/lib/newspaper_web/live/admin_live/articles.ex:25`,
  `:39`, and `:430`.
- Evidence: every relevant event rebuilds entries with `history: []` and
  `history_loaded?: false`. The LiveView probe opens history, delivers one
  processing event, and loses the history list. An open details element can
  now show Loading without any request to reload it.
- Decision: preserve expanded/loaded state across refreshes and update the
  history of expanded articles; bound retained state to visible rows. Coalesce
  processing updates so a busy queue does not repeatedly erase/reload details.
- Tests: open history during a running attempt; unrelated event; attempt
  completion; paging/filtering; collapse/reopen; no stale or permanent Loading
  display. Preserve selected sort and other article filters.

### IMP-13: The navigation Attention badge is not reactive outside Processing

- Severity: Medium. Contract: shared live Attention indicator. Effort: medium.
- Location: `newspaper/lib/newspaper_web/live/admin_live/nav.ex:12`;
  Sources uses `<.nav current="intake" />`, with equivalent static calls on
  Articles, Outputs, and Settings.
- Evidence: the badge performs a query within a function component without a
  changing assign from those parent LiveViews. Updating a source to failed
  and delivering its intake event leaves the badge absent in the UI probe.
  Some of these pages also ignore the other contributing event types entirely.
- Impact: the plan's acknowledged per-render-query compromise does not even
  provide fresh state: LiveView change tracking can skip this static component.
- Decision: pass a reactive count from a shared, coalesced projection/subscription
  with clock-driven expiry. Keep queries out of static render helpers; do not
  load the entire Attention inbox just to count its groups.
- Tests: badge appears, changes, and clears on every top-level page after
  step/feed/entry failures, successful recovery, and backoff expiry without a
  browser refresh. Include no-activity clock expiry and concurrent viewers.

### IMP-14: Pipeline menus reintroduce the outside-click dismissal regression

- Severity: Low. Contract: preserved basic interaction behavior. Effort: small.
- Location: `newspaper/lib/newspaper_web/live/admin_live/pipeline_chain.ex:100`.
- Evidence: the new native `details` menu has none of the existing app's
  dismissal wiring. In the isolated browser preview, opening a step menu,
  clicking the Processing heading, and pressing Escape leaves the same
  `details[open]` present after both actions.
- Impact: the exact awkward menu interaction previously fixed in this app
  returns. More than one step menu can remain open over other controls.
- Decision: reuse the existing dismissal/focus convention, staying within
  LiveView's JS helpers or the already justified shared hook. Close on an
  action and outside click; support Escape and keyboard focus restoration.
- Tests: browser interaction for outside click, Escape, switching menus,
  selecting an action, disabled actions, and a live update while open.

### IMP-15: Queue order, counts, and estimates do not describe actual scheduling

- Severity: Medium. Contract: truthful next/running/waiting read models.
  Effort: medium.
- Location: `newspaper/lib/newspaper_web/live/admin_live/processing.ex:1152`,
  `:1320`, `:1474`; `newspaper/lib/newspaper/processing.ex:1123`.
- Evidence: Queued next uses insertion order, whereas dispatchers prioritize
  foreground work over bulk. The UI assigns position 1 to older bulk work on
  the same host even when a new foreground article will run first. It queries
  5,000 queued attempts across both stages before separating stages, then
  shows only 50 rows per stage with no paging or truncation notice. Extraction
  hosts are flattened alphabetically, so the first host can occupy every row.
  Waiting groups count only the first 250 item steps, while the section total
  counts all item steps and excludes the displayed site-delay executions.
  Running operations are filtered after taking the latest 100 runs.
- Impact: recent foreground news can be hidden behind backlog; an entire
  stage can show a positive count with no displayed work; live old operations
  can disappear. Waiting totals mix populations, obscuring what will run.
  Extraction ETA still uses all queued work with `paused: false`, even when
  every host is in backoff, contrary to the plan's withholding rule.
- Decision: project the actual priority and eligibility policy into bounded
  stage/host/feed queues. Apply predicates before limits, aggregate before
  pagination, and explicitly label any sample. Separate delayed executions
  from prerequisite-blocked item steps. Suppress or explain estimates for
  backoff/blocked work; do not imply a global FIFO across independent hosts.
- Tests: newer foreground behind older bulk; multiple hosts/stages above the
  display limits; live operation older than 100 terminal runs; blocked groups
  above 250; all/mixed hosts in backoff; pending-only and idle states.

### IMP-16: Batch history still uses attempt ownership instead of membership

- Severity: Medium. Contract: C1 and cross-view correlation. Effort: medium.
- Location: `newspaper/lib/newspaper/processing.ex:959`, `:1058`, `:1064`,
  and `:1160`.
- Evidence: both batch attempt lookup and History's batch filter use only
  `attempt.batch_run_id`. A second batch sharing an execution therefore has
  no execution history under its own link. Feed filtering uses current
  `latest_attempt_id`; older shared execution context disappears when the
  consuming item advances to another attempt. Throughput also counts only
  originally owned attempts rather than the batch's demand lifecycle.
- Impact: even after IMP-01 fixes terminal status, the Batches -> History
  navigation still cannot explain what served the batch. Membership only
  records item-step ID/outcome, so it cannot independently reconstruct every
  participating attempt after retries replace the mutable latest pointer.
- Decision: retain immutable member-to-attempt participation/lineage and use
  it for batch/feed drilldowns. Show one execution once with its consumers;
  distinguish member progress from execution throughput. Preserve prior
  independent batches when an article is reprocessed later.
- Tests: shared extraction and digestion; foreground-owned execution joined
  by a batch; automatic retries; later independent reprocessing; archived
  history remaining attributable after current item pointers change.

### IMP-17: Entry recovery can block the page and report success without repair

- Severity: Medium. Contract: C5's exact repair and honest recovery result.
  Effort: medium.
- Location: `newspaper/lib/newspaper/operations/attention.ex:80`;
  `newspaper/lib/newspaper/pipeline.ex:265`, `:284`, `:313`;
  `newspaper/lib/newspaper_web/live/admin_live/processing.ex:158`.
- Evidence: Retry entries executes synchronous sequential replay/refetches
  inside the LiveView callback. Multiple ingestion failures from one feed
  each trigger a complete unconditional fetch. The action drops all error
  reasons and returns an info flash even when every result is an error.
  A successful refetch is considered a successful entry retry even when the
  original entry has aged out of the RSS and its failure remains unresolved.
  The focused probe supplies an empty successful feed to reproduce this.
- Impact: the page can stop processing live events for multiple HTTP timeouts,
  hammer one source repeatedly, and leave the same Attention row with a green
  success message and no explanation. Raw replay is also not scoped to the
  failing output; disabled/deleted/no-longer-eligible outputs can yield no
  errors without repairing that output's recorded failure.
- Decision: run recovery under supervised, visible operation tracking; group
  unconditional fetches by source and revalidate each exact failure afterward.
  Return repaired, still-failed, entry-missing, and target-unavailable results
  separately. Keep historical evidence, record retry attempts, and never
  conflate successful transport with repaired publication/ingestion.
- Tests: missing entry in 200 response; 304 avoidance; several failures in
  one source; one repaired/one still broken; deleted/disabled output; process
  failure; repeated click; LiveView remains responsive during slow replay.

### IMP-18: The read-model implementation repeats unbounded work per viewer

- Severity: Medium. Contract: bounded/coalesced projections. Effort: medium.
- Location: `newspaper/lib/newspaper/operations/attention.ex:40`, `:49`,
  `:95`; `newspaper/lib/newspaper_web/live/admin_live/processing.ex:1144`,
  `:1155`, `:1233`; `newspaper/lib/newspaper/processing.ex:967`.
- Evidence: `Attention.count/0` loads every failed item and unresolved entry,
  builds every group and item action, and then counts groups. Attention tab
  immediately repeats that work to render the groups. Queue hydrates up to
  5,000 attempts and their full article, rendered item, run, and consumer
  associations to show 50 rows. The 300 ms event coalescer and 30-second timer
  are per LiveView, not a shared projection, so every open viewer repeats it.
- Impact: a large backlog/failure period makes the operational UI most
  expensive exactly when it is needed most. Full rendered article bodies can
  dominate transfer/allocation even though list rows only need a few fields.
  This is a code-supported scaling risk, not a claimed production benchmark.
- Decision: use SQL aggregate counts and compact projections; paginate detail
  rows, load expanded groups on demand, and share expensive count snapshots
  across viewers with event invalidation and time-driven expiry. Reuse the
  same snapshot for badge and body. Avoid doing I/O inside render components.
- Tests: query/allocation bounds with thousands of failed/queued items and
  large article bodies; more than one subscribed viewer; burst coalescing;
  timer expiry; detail expansion does not load unrelated groups.

### IMP-19: Attention's per-item actions lack article identity and drilldowns

- Severity: Medium. Contract: actionable, correlated diagnostics. Effort: small.
- Location: `newspaper/lib/newspaper/operations/attention.ex:95` and
  `newspaper/lib/newspaper_web/live/admin_live/processing.ex:700`.
- Evidence: a failed-step group's rows contain only an item-step ID, repeated
  error-message label, and timestamp. They do not select the article title,
  URL/GUID, attempt ID, or run/batch context, and the expanded row has Retry
  but no article/history link. Many rate-limited articles become visually
  identical rows. Feed-held counts are also text only, without a reason/item
  drilldown in the Pipeline chain.
- Impact: the operator cannot choose which article to retry or correlate
  Attention with Articles and History without manually searching elsewhere.
  This recreates the disconnected windows that motivated the redesign.
- Decision: provide identifiable article rows and contextual history links
  while retaining group-level actions. Link held-publication counts to a
  scoped explanation of unmet item-step/rendering requirements, including
  disabled definitions whose old snapshots still demand processing.
- Tests: two different articles with identical error messages; shared article
  in two output feeds; missing/deleted targets; held output with mixed causes;
  links preserve relevant feed/article/stage context.

### IMP-20: Membership migration assigns other feeds to the originating batch

- Severity: High. Contract: C1/C2 and rollout safety. Effort: medium.
- Location: `newspaper/priv/repo/migrations/20260914220000_create_pipeline_batch_members.exs:29`.
- Evidence: the backfill joins item steps by direct owner OR any current
  `latest_attempt_id` reference, then assigns all of them to the attempt's
  original batch. There is no check that the item's output matches the batch's
  `related.generated_feed_id`. The audit probe runs that SQL selection against
  two feeds sharing an attempt and gets both item steps under batch A.
- Impact: existing batch totals expand to include unrelated feed B. Cancelling
  A after rollout can withdraw B's work even though B never belonged to A's
  request. Conversely, B's own batch membership cannot be reconstructed by
  the originating foreign key alone. An early failed attempt followed by an
  unowned automatic retry can also seed a prematurely terminal outcome.
- Decision: rehearse migration against representative pre-change rows.
  Recover membership only from valid same-feed, same-stage request evidence;
  explicitly handle ambiguity in legacy shared/retried work rather than
  inventing cross-feed ownership. Preserve active demand and frozen terminal
  history. Account for older failures whose new `resolved_at` starts null:
  reconcile already-repaired entries instead of presenting all historical
  failures as newly actionable by default.
- Tests: upgrade with shared running/queued/succeeded attempts, retry chains,
  multiple historical batches, and already-repaired failure records. Validate
  totals, cancellation isolation, history, and restart dispatch after upgrade.

### IMP-21: Re-render failures still fall outside the Attention recovery model

- Severity: Medium. Contract: C5 includes publication/re-render errors.
  Effort: medium.
- Location: `newspaper/lib/newspaper/pipeline.ex:215` and
  `newspaper/lib/newspaper/operations/attention.ex:29`.
- Evidence: re-render stores only an aggregate failed run and a count of failed
  items. It does not create individually attributable unresolved failures.
  Attention selects three entry failure types and abandoned running operations;
  a finished failed re-render matches neither. The returned per-item errors
  are discarded, so History cannot tell which rendered item failed either.
- Impact: users can change output rendering, encounter stale publication, and
  still see no Attention cause or scoped retry. The new inbox is not yet a
  complete replacement for checking operation outcomes manually.
- Decision: persist exact item/output failure identity and diagnostic cause
  for re-render errors; resolve only the repaired target on successful replay.
  Expose a supervised scoped retry and link it back to its operation history.
- Tests: partially failing re-render, later successful repair, output disabled
  or deleted, unaffected items untouched, and no duplicate Attention groups
  for historical failed attempts that have already been repaired.

### IMP-22: A rejected pipeline toggle displays the opposite of saved state

- Severity: Medium. Contract: accurate configuration feedback. Effort: small.
- Location: `newspaper/lib/newspaper_web/live/admin_live/pipeline_chain.ex:89`
  and `newspaper/lib/newspaper_web/live/admin_live/processing.ex:72`.
- Evidence: with extraction and digestion enabled, click extraction's switch.
  The server correctly rejects disabling a prerequisite and flashes the error,
  but only the flash assign changes. The native checkbox has already unchecked
  itself. Browser inspection after the reply shows `checked == false` while
  the server-rendered `checked` attribute is still present.
- Impact: the page appears to have disabled work that is still enabled. A
  second click can request the same rejected transition instead of restoring
  the displayed state. Static template/LiveViewTest assertions do not observe
  the browser's changed checkbox property, so they can miss this regression.
- Decision: use a LiveView-native controlled form/action that reflects the
  accepted server value, including rejection. Disable predictably unavailable
  transitions with a reason while still enforcing all rules server-side.
  Do not add a separate client-side source of processing/configuration truth.
- Tests: browser property after dependency, rendering, and active-work
  rejection; valid toggle; rapid repeat click; another viewer changes the
  same definition; rejected changes must never look saved.

## Not Findings

- The information architecture itself follows the approved direction:
  Processing as home, Sources for intake/site configuration, Outputs for
  membership and rendering, Articles for article-level inspection, and
  Settings for global configuration. The concerns above are not a request
  to restore the old page layout.
- Fixed registry-driven step order and deferred source-scoped enrichment are
  intentional. No generic workflow engine, arbitrary DAG, plugin system, or
  upstream enrichment implementation is needed to reconcile this audit.
- Cancellation cascading to downstream unstarted demand is Ian's decision,
  not an overreach by Fable. The implementation must honor it consistently
  while leaving shared live demand intact.
- Restricting abandoned-run closure to non-pipeline operations is a reasonable
  conservative scope. The action's validation/ownership identity still needs
  IMP-10; paused or rate-limited work must not be treated as abandoned.
- Legacy `/runs` and `/sites` route removal follows the reconciled route
  decision. Ordinary old context links into `/processing` still matter and
  are the distinct problem in IMP-11.
- Internal-only hosting/VPN access remains the accepted security posture.
  This UI audit does not reopen authentication/public-exposure requirements.
  Hosted article/RSS identity, executable contracts, and extractor algorithms
  are not being redesigned by this patch.

## Verification Boundaries

Baseline evidence: `scripts/test.sh` passes 162 Elixir tests and 25 worker
tests. The separate audit command fails all 17 probes for their stated
assertions. `git diff --check` reports no whitespace errors. Only audit
documentation/probes were added; application changes remain Fable's unmodified
working tree. Temporary browser/server fixtures were stopped and rolled back.

Before accepting fixes, require the maintained full suite plus the focused
contract tests above. Promote the audit probes into the appropriate maintained
test modules; retain red-before-green evidence. Add deterministic concurrency
barriers rather than sleeps for enrollment, claims, cancellation, and restart.
Exercise each lifecycle for both extraction and digestion, shared and unshared,
with pause/backoff and subsequent independent retries.

Rehearse the migration on an isolated representative pre-change database;
the SQL selection probe is not a full production-data upgrade rehearsal.
Measure query/allocation bounds before claiming the projection cache/scaling
contract. No production database or deployment was used for this audit.

Responsive and polished visual verification remains open. `mix assets.build`
exits 137 in the local standalone Tailwind binary, including after reinstalling
the pinned version. The same-version npm fallback fails to load the vendored
daisyUI plugin options under both installed Node and Node 22. Neither issue is
attributed to Fable's application changes without further evidence. Do not
treat the existing generated CSS as a valid visual signoff. Rebuild in the
supported build environment and inspect desktop/mobile views, long labels,
expanded Attention groups, menus, and keyboard navigation before release.

## Reproduction Tests

`planning/audit/probes/02_processing_lifecycle_test.exs` contains isolated
assertions of the intended contracts. Run from `newspaper/` with:

```sh
mix test ../planning/audit/probes/02_processing_lifecycle_test.exs
mix test ../planning/audit/probes/02_attention_recovery_test.exs
mix test ../planning/audit/probes/02_processing_ui_test.exs
```

These are deliberately outside the normal suite and should fail until their
findings are resolved. Move appropriate cases into maintained test modules
when implementing fixes. The normal suite passing is not evidence that the
uncovered interleavings or shared-consumer paths are correct.
