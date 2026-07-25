# Strengths — Do Not "Fix" These

A skeptical audit should also mark what is correct and deliberate, so the
fix-up phase doesn't churn good code. These observed behaviors match the
planning docs closely and are, in several cases, subtle to get right.

## Faithful-to-spec behaviors verified during the audit

- **Rate-limit and escalation semantics** (`extraction.ex`, `content.ex`,
  worker `classifyHttpFailure`): first simple-client 429 backs off honoring
  `Retry-After` without escalating; a second rate-limited attempt probes
  Headless in the same attempt; a rate-limited headless probe preserves
  adaptive backoff and does not escalate further; success clears backoff and
  may teach the site minimum, gated on `escalation_enabled`. All of this
  matches `pipeline.md`/`features/006` exactly and is covered by targeted
  tests (backoff growth to the 30-minute cap, server Retry-After exceeding the
  cap, learn-on-success).
- **Automatic retry budget**: durable queued retries for rate limits with a
  finite budget (3), then a visible manually-retryable failure — matches
  "Automatic retries should have a finite budget; exhausting it leaves a
  visible, manually retryable failure."
- **`not_found` permalink recovery**: same-site, URL-shaped feed GUID fallback
  with the redirect target becoming the resolved URL, terminal-but-retryable
  otherwise — matches the plan's stale-permalink paragraph, tested.
- **No-content as skipped, not failed**: terminal no-content creates no
  failure record, skips downstream digestion, and later successful
  re-extraction reactivates skipped digestion steps
  (`reactivate_skipped_article_steps`) — matches `pipeline.md` and was
  retro-fitted to historical data via a careful migration.
- **Foreground-before-bulk priority** derived from durable
  `batch_run_id` (`PriorityQueue`, `list_queued_attempts` ordering), surviving
  restart without an in-memory flag — matches the priority paragraph verbatim.
- **Restart recovery for attempts and batches**: `running → queued` requeue,
  interrupted diagnostic runs closed as interrupted, batch enrollment resumed
  from durable context by a supervised dispatcher, enrollment surviving the
  requesting process exiting — all specced, all tested.
- **Rendering-policy saves auto-trigger scoped re-render** with GUID
  stability; backfill vs re-render kept as distinct verbs; digest-selected
  items wait (`publication_status: "processing"`) rather than silently falling
  back to originals — matches `rss-output-shape.md`/`workflow.md`.
- **Digest model snapshotting**: item steps snapshot model + prompt/schema
  versions with a definition fingerprint; execution uses the snapshot, and
  artifacts are versioned, fingerprinted, reused when identical, and never
  mutated on re-digestion. `think: false` and no chain-of-thought storage
  matches the plan.
- **Worker contract**: versioned JSON on stdin/stdout, stderr for
  diagnostics, normalized failure taxonomy, shared response shape across
  simple/headless — matches `architecture.md` Worker Responsibilities. The
  extracted HTML is properly **sanitized at the worker boundary**
  (sanitize-html with a tight allowlist, URL absolutization,
  `rel="noopener noreferrer"`), which makes the `raw/1` rendering on the
  hosted article page safe.
- **Site policy as host-scoped coordinator**: output feeds select only
  `extraction.site_policy`; extractor choice, pacing, timeout, and quality
  thresholds live on the host policy; policy CRUD validates implementations
  against the code registry. Matches the two-registry-roles design.
- **Enabled/disabled semantics**: disabled input feeds not fetched, disabled
  groups make children inactive, disabled output feeds 404 and stop creating
  items, future-only enablement with explicit bulk actions for existing items.
- **UTC storage + browser-local rendering** via the `LocalTime` hook matches
  the operator-visibility requirement.
- **Scheduler**: fetch-on-start, timer re-arm on settings change,
  no-overlap-of-global-fetches — specced and tested with injected
  fetcher/interval providers.

## Process strengths

- Test suite is behavior-oriented (named after specced behaviors, not
  functions), uses proper OTP synchronization patterns, and covers the
  hardest specced flows (escalation ladders, restart recovery, batch
  lifecycle) rather than trivia.
- Migrations are careful: data-preserving up/down where feasible, honest
  irreversibility (`classify_no_content_as_skipped` raises on down), and
  backfills for new bookkeeping tables.
- The Dockerfile keeps the headed/authenticated tier host-owned and the
  disposable extractors in-image, exactly per `prod-topology.md`.
