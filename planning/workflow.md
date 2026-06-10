# Workflow Model

## Direction

Use explicit workflow state, but keep the first implementation lightweight.

The system should not need a full workflow engine for V1. It should have enough durable state to explain what happened to a feed item, why it did or did not appear downstream, and what failed.

Use eager durable evaluation. Fetching and processing input feeds should create durable raw item, article, source appearance, generated feed item records, and rendered RSS snapshots. Output feeds should render from app-owned snapshots rather than lazily mirroring current upstream feed contents or live-rendering current article state.

## V1 Flow

```text
source enabled
  -> feed fetched
  -> raw item discovered
  -> intake group resolved
  -> URL canonicalized within intake group
  -> article identity resolved into article pool
  -> source appearance recorded
  -> output feed eligibility determined
  -> generated feed item record created or updated
  -> rendered RSS snapshot stored
  -> generated RSS published
```

## Later Extraction Flow

```text
generated feed item available
  -> extraction queued
  -> page fetched
  -> article content parsed
  -> generated feed item upgraded
  -> extraction failure recorded when needed
```

## State Strategy

Prefer simple, explicit state fields and failure records over a general-purpose workflow framework.

Likely useful concepts:

- Source fetch status.
- Intake group processing status.
- Raw item discovery state.
- Canonical article status.
- Generated feed publication state.
- Generated feed item eligibility/publication state.
- Generated feed item render snapshot state.
- Extraction status, even if unused in V1.
- Failure type, message, retry count, and last attempt timestamp.

## Event Framing

Worker results can be treated as proposed domain events.

```text
worker output = proposed event
control plane = validates event and mutates owned state
```

This framing can guide contracts without requiring event sourcing from day one.

## Failure Handling

Failures should be visible and retryable where practical.

V1 failure handling should be minimal: show failures, link them to related records/runs where possible, and allow manual retry for retryable failures. Do not add automatic retry/backoff behavior or manual resolved/ignored/dismissed lifecycle states until real usage clarifies what is needed.

Examples:

- Source feed fetch failed.
- Feed parsing failed.
- Intake-group canonicalization produced ambiguous matches.
- Generated feed render failed.
- Extraction auth expired.
- Extraction failed.
- Classifier output failed schema validation.

V1 only needs the feed-related failures, but the model should not block later extraction failures.

Re-rendering should be explicit. When extraction succeeds or settings change later, the system should update generated feed item snapshots through a deliberate reprocess path rather than changing output implicitly on every RSS request.

## Configuration Changes

Configuration changes should be future-only by default.

Changing output feed membership, source settings, or rendering settings should not automatically rewrite existing generated feed items or backfill old articles into feeds. The user should be able to trigger an explicit manual rebuild/backfill/re-render action when they want existing app-owned records to be reconsidered.

## Enabled / Disabled Semantics

Keep enabled/disabled behavior simple in V1.

- Disabled input feeds are not fetched.
- Disabled intake groups make their child input feeds inactive for fetching.
- Disabled output feeds do not create new generated feed items.
- Disabling anything should not delete raw items, articles, source appearances, or existing generated feed items.
- Re-enabling resumes future processing only unless the user explicitly runs a manual backfill/rebuild/re-render action.
- A disabled output feed endpoint should return `404`.

Avoid more elaborate semantics until real usage shows they are needed.

## Manual Actions

Use precise operational verbs. These actions should not be blurred together.

### Fetch

Fetch gets new raw feed entries from configured input feeds.

Fetch may create raw items, but it should not rewrite generated feed item history directly.

V1 fetch triggering should include manual fetch and a global scheduled fetch interval. The default interval is 60 minutes and should be configurable in the admin UI. Per-feed schedules are deferred.

Use supervised GenServer-style orchestration in V1. Do not introduce Oban unless later job complexity makes it worthwhile.

Persist run records for meaningful operations even though orchestration is GenServer-based. V1 should favor verbose debugging history over minimal storage. Run logging can become configurable or disabled later if it becomes noisy.

Initial V1 run types:

- `fetch_all`
- `fetch_input_feed`
- `process_intake_group`
- `backfill_output_feed`
- `rerender_output_feed`

Run records should include a trigger such as `manual`, `scheduled`, or `system`. This taxonomy is expected to change after real usage.

### Dedupe / Canonicalize

Dedupe/canonicalize resolves raw items into canonical article records and source appearances within intake groups.

### Backfill

Backfill creates missing generated feed items from already-ingested articles.

Use backfill when output feed rules change and the user explicitly wants older matching articles to appear in an output feed. Backfill is scoped to an output feed in the first implementation. It should not delete, replace, or rewrite existing generated feed items.

### Re-render

Re-render updates rendered RSS snapshots for existing generated feed items.

Re-render is scoped to an output feed in the first implementation. It uses app-owned stored data, such as raw item data, article data, extraction data, and output feed rendering settings. It should not fetch upstream RSS again, mutate raw intake records, or change generated feed item GUIDs.

### Extract

Extract fetches and parses article pages, then stores extracted article content and extraction metadata.

Extraction is separate from re-rendering. A later re-render may use extracted content if it exists.

### Rebuild

Rebuild is a broader and potentially dangerous administrative action that recomputes generated feed item state for a scope.

Rebuild may delete, archive, replace, or mark stale existing generated feed items depending on the chosen mode. It should not be the default V1 path. Prefer safer explicit actions such as backfill missing items and re-render existing items.

## Retention

Old raw items, articles, and generated feed items can be autopurged later if needed. Retention should be an explicit policy, not a side effect of source feeds dropping old entries or input feeds being disabled.
