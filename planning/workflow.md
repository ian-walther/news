# Workflow Model

## Direction

Use explicit workflow state, but keep the implementation lightweight.

The system should not need a full workflow engine. It should have enough durable state to explain what happened to a feed item, why it did or did not appear downstream, and what failed.

Use eager durable evaluation. Fetching and processing Input Feeds should create
durable Raw Items, Outlet-specific Articles, Article Appearances, shared
extraction and classification artifacts, generated feed items, and rendered
RSS snapshots. Output Feeds and Newspaper Editions should render from
app-owned snapshots rather than mutable live state.

## Feed Flow

```text
input feed enabled
  -> feed fetched
  -> raw item discovered
  -> required Outlet boundary resolved
  -> URL and feed stable ID canonicalized within that Outlet
  -> article identity resolved into article pool
  -> Article Appearance recorded
  -> upstream extraction and classification requested by policy
  -> output feed eligibility determined
  -> generated feed item record created or updated
  -> rendered RSS snapshot stored
  -> generated RSS published
```

## Shared Enrichment Flow

```text
Article available
  -> upstream enrichment policy requests extraction
  -> step attempt recorded
  -> extraction implementation runs
  -> reusable Article Extraction stored
  -> classification implementation runs
  -> reusable Article Classification stored
  -> waiting Reading Feed and Newspaper work advances
  -> failure recorded when needed
```

Output Feed membership is not required. Existing output-scoped extraction
history remains valid through migration, but new demand converges on one shared
Article artifact.

## Digestion Flow

```text
generated feed item available
  -> enabled digestion step checks for successful extraction
  -> step attempt recorded
  -> snapshotted global Ollama model produces one structured title and summary
  -> result validated and stored as a versioned article digest
  -> generated feed item re-rendered when configured to use digest output
  -> failure recorded when generation or validation fails
```

Articles without a successful extraction are not eligible for digestion. The digest step should wait on that prerequisite rather than silently using a raw feed body.

## Newspaper Flow

```text
content cutoff reached
  -> eligible Article and configuration revisions sealed in a manifest
  -> cross-Outlet Articles clustered into Events
  -> weighted admission and section placement evaluated
  -> Claims, evidence relationships, and uncertainty analyzed
  -> valid Edition Stories synthesized and citation-checked
  -> at delivery deadline, complete valid stories sealed
  -> hosted Edition published
  -> delivery email sent
```

One or more valid Edition Stories publishes a possibly thin Edition. Zero
valid stories records a failed Edition run and sends a failure notification.
Late or incomplete work moves to the next Edition rather than mutating the
sealed artifact.

## State Strategy

Prefer simple, explicit state fields and failure records over a general-purpose workflow framework.

Useful state concepts should remain bounded to:

- Source fetch status.
- Outlet canonicalization and enrichment status.
- Raw item discovery state.
- Canonical article status.
- Article Appearance state.
- Generated feed publication state.
- Generated feed item eligibility/publication state.
- Generated feed item render snapshot state.
- Pipeline step configuration.
- Generated feed item step snapshot and status.
- Pipeline step attempt status.
- Extraction status.
- Classification status.
- Event clustering and admission status.
- Edition phase, publication, and delivery status.
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

Scope should follow the artifact being produced:

- Outlet and Input Feed policy scopes request shared extraction and Article
  classification.
- Host policy controls extraction strategy, escalation, pacing, timeout, and
  quality thresholds.
- Output Feed scope controls filtering, digestion, and rendering.
- Newspaper config scope controls clustering, admission, synthesis, Edition
  rendering, and delivery.

Output Feeds must not select competing extraction methods for the same Article.
Enabling upstream enrichment applies to future Articles; existing Articles
require an explicit backfill. Output title, body, link, and hosted-page
settings only decide how available artifacts are presented.

## Failure Handling

Failures should be visible and retryable where practical.

Failure handling should stay minimal: show failures, link them to related records/runs where possible, and allow manual retry for retryable failures. Avoid manual resolved/ignored/dismissed lifecycle states until real usage clarifies what is needed.

Examples:

- Source feed fetch failed.
- Feed parsing failed.
- Outlet canonicalization produced ambiguous matches.
- Generated feed render failed.
- Extraction auth expired.
- Extraction failed.
- Digest output failed schema validation.
- The configured Ollama server or selected model is unavailable.
- Classifier output failed schema validation.
- Event clustering created an invalid or ambiguous merge.
- Claim or Citation validation failed.
- Edition generation missed the delivery deadline.
- Edition delivery failed after successful publication.

The model should support feed, extraction, digestion, filtering, rendering, and worker contract failures.

Current extraction workers should report concrete observable outcomes such as rate limiting, missing pages, blocked responses, unsupported content types, timeouts, network failures, and no usable content. Semantic distinctions such as paywall, expired authentication, and JavaScript-required should be introduced only with deterministic detection from representative real pages. Digestion failures should distinguish configuration, model/HTTP, connection, and structured-output errors so retryability reflects the actual failure class.

Re-rendering should remain an explicit application operation rather than live computation on each RSS request. Successful extraction or digestion should refresh affected snapshots, and saving output title, body, or link rendering policy should deliberately start a scoped re-render from app-owned artifacts.

## Configuration Changes

Processing and membership changes should be future-only by default.

Changing output feed membership or source settings should not automatically rewrite existing generated feed items or backfill old articles into feeds. Changing title, body, link, or hosted-page presentation policy is different: saving that policy should automatically re-render existing generated feed items from their stored artifacts so published links and feed snapshots match the selected presentation. A manual re-render remains available as a recovery and debugging action.

## Enabled / Disabled Semantics

Keep enabled/disabled behavior simple.

- Disabled input feeds are not fetched.
- Disabled Outlets make their Input Feeds inactive for fetching.
- Disabled output feeds do not create new generated feed items.
- Disabled pipeline steps do not schedule future attempts of that step type.
- Disabling anything should not delete Raw Items, Articles, Article
  Appearances, artifacts, Editions, or existing generated feed items.
- Re-enabling resumes future processing only unless the user explicitly runs a manual backfill or rebuild action. Rendering-policy saves may re-render existing snapshots but must not request new extraction or digestion work.
- A disabled output feed endpoint should return `404`.

Avoid more elaborate semantics until real usage shows they are needed.

## Manual Actions

Use precise operational verbs. These actions should not be blurred together.

### Fetch

Fetch gets new raw feed entries from configured input feeds.

Fetch may create raw items, but it should not rewrite generated feed item history directly.

Fetch triggering should stay simple: manual fetch and a global scheduled fetch interval, defaulting to five minutes. The scheduler should collect immediately after application startup, re-arm its current timer when the global interval changes, and prevent scheduled and manual global fetches from overlapping. Per-feed schedules remain deferred.

Use supervised GenServer-style orchestration for now. Do not introduce Oban unless later job complexity makes it worthwhile.

Persist run records for meaningful operations even though orchestration is GenServer-based. Favor verbose debugging history over minimal storage while the pipeline shape is still evolving. Run logging can become configurable or disabled later if it becomes noisy.

Run types to preserve or extend:

- `fetch_all`
- `fetch_input_feed`
- `process_outlet`
- `backfill_output_feed`
- `rerender_output_feed`
- `backfill_article_enrichment`
- `generate_edition`
- `deliver_edition`

Run triggers describe why work began:

- `manual`: an operator explicitly requested the operation.
- `scheduled`: the global feed timer requested collection.
- `system`: a parent operation created an internal child run.
- `pipeline`: a durable pipeline attempt started its execution run.
- `settings_change`: saving rendering policy requested a scoped re-render.

New trigger values should be added deliberately with matching Processing visibility and overview behavior.

### Dedupe / Canonicalize

Dedupe/canonicalize resolves Raw Items into Outlet-specific canonical Articles
and Article Appearances.

### Backfill

Backfill creates missing generated feed items from already-ingested articles.

Use backfill when output feed rules change and the user explicitly wants older matching articles to appear in an output feed. Backfill should remain explicit and scoped. It should not delete, replace, or rewrite existing generated feed items.

### Re-render

Re-render updates rendered RSS snapshots for existing generated feed items.

Re-render uses app-owned stored data, such as raw item data, article data, extraction data, and output feed rendering settings. It should not fetch upstream RSS again, mutate raw intake records, or change generated feed item GUIDs.

Saving output title, body, or link rendering policy should automatically start this operation for the affected feed. The manual action remains useful when snapshots need to be repaired without changing policy.

### Extract

Extract fetches and parses article pages, then stores extracted article content and extraction metadata.

Extraction is a shared Article pipeline step whose upstream enrichment policy
delegates to host policy. Simple HTML, headless browser, and headed browser are
separate strategies behind one contract.

The Elixir app owns escalation. It should decide whether to try the next extractor in the chain and should persist site-level minimum extractor policy when a site is known to require a more capable implementation.

Extraction is separate from re-rendering. A later re-render may use extracted content if it exists.

### Classify

Classify produces a versioned app-owned Article Classification from extracted
content and metadata hints. Output Feed filters and Newspaper policy reuse that
artifact instead of treating sub-feed categories as authoritative.

### Filter

Filter decides whether an article should remain eligible for an output feed, be excluded, or route to review.

Filtering is an Output Feed pipeline step. Deterministic policy evaluation and
model-assisted review are separate implementations, but both should consume
the shared Article Classification when possible.

### Digest

Digest produces one durable factual replacement title and reading summary from a successful article extraction.

Digestion is a pipeline step type. The `digestion.ollama.article_digest` implementation snapshots the global model and bounded config for each generated feed item. Existing eligible articles are processed through an explicit bulk action; explicit re-digestion creates a new artifact while preserving earlier artifacts and attempts.

### Generate Edition

Generate Edition freezes a manifest at cutoff, clusters Events, applies
weighted admission, analyzes Claims and evidence, synthesizes and validates
Edition Stories, then seals complete work at the delivery deadline. Reruns use
the same manifest and never become manual prose-editing sessions.

### Rebuild

Rebuild is a broader and potentially dangerous administrative action that recomputes generated feed item state for a scope.

Rebuild may delete, archive, replace, or mark stale existing generated feed items depending on the chosen mode. It should not be the default path. Prefer safer explicit actions such as backfill missing items and re-render existing items.

## Retention

Old Raw Items, Articles, and generated feed items can be autopurged later if
needed. Retention should be explicit, not a side effect of source feeds
dropping old entries or Input Feeds being disabled. Immutable Editions,
Citations, corrections, stable RSS identity, and every referenced artifact
must be protected.
