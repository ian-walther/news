# Workflow Model

## Direction

Use explicit workflow state, but keep the implementation lightweight.

The system should not need a full workflow engine. It should have enough durable state to explain what happened to a feed item, why it did or did not appear downstream, and what failed.

Use eager durable evaluation. Fetching and processing input feeds should create durable raw item, article, source appearance, generated feed item records, and rendered RSS snapshots. Output feeds should render from app-owned snapshots rather than lazily mirroring current upstream feed contents or live-rendering current article state.

## Feed Flow

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

## Extraction Flow

```text
generated feed item available
  -> enabled extraction step requests article extraction
  -> step attempt recorded
  -> extraction implementation runs
  -> article content stored
  -> generated feed item re-rendered when configured
  -> failure recorded when needed
```

## Digestion Flow

```text
generated feed item available
  -> enabled digestion step checks for successful extraction
  -> step attempt recorded
  -> selected Ollama model produces one structured title and summary
  -> result validated and stored as a durable article digest
  -> generated feed item re-rendered when configured to use digest output
  -> failure recorded when generation or validation fails
```

Articles without a successful extraction are not eligible for digestion. The digest step should wait on that prerequisite rather than silently using a raw feed body.

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
- Pipeline step configuration.
- Pipeline step attempt status.
- Extraction status.
- Failure type, message, retry count, and last attempt timestamp.

## Event Framing

Worker results can be treated as proposed domain events.

```text
worker output = proposed event
control plane = validates event and mutates owned state
```

This framing can guide contracts without requiring event sourcing from day one.

## Configurable Steps

Processing steps should be user-configurable in the admin UI.

Each step should have a type, implementation key, enabled flag, position, and config. The available implementations should come from a code-owned registry so the UI can be configurable without allowing arbitrary executable behavior from the database.

The first configurable scope should be output feeds. Additional scope inheritance should wait until output-feed pipelines are useful.

For extraction, the output-feed step only enables the site-policy coordinator. The article host owns the starting extractor, escalation, pacing, timeout, and extraction-quality thresholds. Output feeds must not select competing extraction methods for the same article.

The extraction step's enabled state is the output-level scheduling control. It automatically requests extraction for future generated feed items. Enabling it is not retroactive; the operator must explicitly request extraction of existing items. Output link and body settings only decide how an available extraction artifact is rendered.

## Failure Handling

Failures should be visible and retryable where practical.

Failure handling should stay minimal: show failures, link them to related records/runs where possible, and allow manual retry for retryable failures. Avoid manual resolved/ignored/dismissed lifecycle states until real usage clarifies what is needed.

Examples:

- Source feed fetch failed.
- Feed parsing failed.
- Intake-group canonicalization produced ambiguous matches.
- Generated feed render failed.
- Extraction auth expired.
- Extraction failed.
- Digest output failed schema validation.
- The configured Ollama server or selected model is unavailable.
- Classifier output failed schema validation.

The model should support feed, extraction, digestion, filtering, rendering, and worker contract failures.

Re-rendering should be explicit. When extraction succeeds or settings change later, the system should update generated feed item snapshots through a deliberate reprocess path rather than changing output implicitly on every RSS request.

## Configuration Changes

Configuration changes should be future-only by default.

Changing output feed membership, source settings, or rendering settings should not automatically rewrite existing generated feed items or backfill old articles into feeds. The user should be able to trigger an explicit manual rebuild/backfill/re-render action when they want existing app-owned records to be reconsidered.

## Enabled / Disabled Semantics

Keep enabled/disabled behavior simple.

- Disabled input feeds are not fetched.
- Disabled intake groups make their child input feeds inactive for fetching.
- Disabled output feeds do not create new generated feed items.
- Disabled pipeline steps do not schedule future attempts of that step type.
- Disabling anything should not delete raw items, articles, source appearances, or existing generated feed items.
- Re-enabling resumes future processing only unless the user explicitly runs a manual backfill/rebuild/re-render action.
- A disabled output feed endpoint should return `404`.

Avoid more elaborate semantics until real usage shows they are needed.

## Manual Actions

Use precise operational verbs. These actions should not be blurred together.

### Fetch

Fetch gets new raw feed entries from configured input feeds.

Fetch may create raw items, but it should not rewrite generated feed item history directly.

Fetch triggering should stay simple: manual fetch and a global scheduled fetch interval. Per-feed schedules remain deferred.

Use supervised GenServer-style orchestration for now. Do not introduce Oban unless later job complexity makes it worthwhile.

Persist run records for meaningful operations even though orchestration is GenServer-based. Favor verbose debugging history over minimal storage while the pipeline shape is still evolving. Run logging can become configurable or disabled later if it becomes noisy.

Run types to preserve or extend:

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

Use backfill when output feed rules change and the user explicitly wants older matching articles to appear in an output feed. Backfill should remain explicit and scoped. It should not delete, replace, or rewrite existing generated feed items.

### Re-render

Re-render updates rendered RSS snapshots for existing generated feed items.

Re-render uses app-owned stored data, such as raw item data, article data, extraction data, and output feed rendering settings. It should not fetch upstream RSS again, mutate raw intake records, or change generated feed item GUIDs.

### Extract

Extract fetches and parses article pages, then stores extracted article content and extraction metadata.

Extraction is a pipeline step type whose output-scoped coordinator delegates to a host policy. Simple HTML extraction, headless browser extraction, and headed browser extraction are separate extractor strategies behind a shared contract.

The Elixir app owns escalation. It should decide whether to try the next extractor in the chain and should persist site-level minimum extractor policy when a site is known to require a more capable implementation.

Extraction is separate from re-rendering. A later re-render may use extracted content if it exists.

### Filter

Filter decides whether an article should remain eligible for an output feed, be excluded, or route to review.

Filtering is a pipeline step type. Source-policy filtering and local-LLM topic filtering are separate implementations of that type.

### Digest

Digest produces one durable factual replacement title and reading summary from a successful article extraction.

Digestion is a pipeline step type. The initial `digestion.ollama.article_digest` implementation stores the selected model and bounded config on the output-feed step. Existing eligible articles are processed through an explicit `Digest existing articles` bulk action; successful artifacts are regenerated only through an explicit re-digest action.

### Rebuild

Rebuild is a broader and potentially dangerous administrative action that recomputes generated feed item state for a scope.

Rebuild may delete, archive, replace, or mark stale existing generated feed items depending on the chosen mode. It should not be the default path. Prefer safer explicit actions such as backfill missing items and re-render existing items.

## Retention

Old raw items, articles, and generated feed items can be autopurged later if needed. Retention should be an explicit policy, not a side effect of source feeds dropping old entries or input feeds being disabled.
