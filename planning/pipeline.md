# Pipeline Architecture

## Core Abstraction

The system is a pipeline with two separate feed concepts:

- Input feeds enter the system through intake groups.
- Output feeds are published to FreshRSS after selection, categorization, filtering, and rendering.

Intake groups and output feeds should not be collapsed into one abstraction.

The pipeline should use eager durable intake, not lazy mirroring of current upstream feed contents. Input feeds are discovery sources. Once discovered, raw items, canonical articles, source appearances, and generated feed items become app-owned durable records.

The app should store enough raw parsed feed data and later rendered metadata that it does not need to consult the original upstream feed entry after ingestion.

## Vocabulary

### Input Feed

An input feed is a raw RSS or Atom URL from an upstream source.

Examples:

- WSJ Technology
- WSJ Markets
- Ars Technica
- Local news feed

### Intake Group

An intake group is an aggregation and deduplication unit for related input feeds.

An intake group commonly represents one outlet or one logical source family. For example, a WSJ intake group may contain several WSJ sub-feeds. The intake group preserves every raw source appearance while resolving repeated entries to one canonical article record.

Deduplication belongs primarily at the intake-group layer.

### Article Pool

The article pool is the durable set of canonical articles produced by intake groups.

Article records preserve source appearances, source metadata, stable app-generated article identity, extraction state, classification state, and later digest/newspaper metadata.

### Output Feed

An output feed is a generated RSS feed consumed by FreshRSS.

Output feeds select from the article pool. They are commonly category feeds, but the mechanism should be generic enough to support review feeds, source bundles, and later policy-filtered feeds.

Categorization, filtering, and routing belong primarily at the output-feed layer.

Output feeds also control RSS rendering settings such as whether item links point to original articles or hosted extracted article pages, whether item titles use original or generated digest titles, and whether item bodies use original feed content, extracted content, or digest summaries.

Output feeds should have stable app-generated identities for feed URLs and feed-level metadata. Generated feed items should also have stable app-generated identities and act as durable publication records.

### Policy

A policy controls output-feed eligibility, filtering, routing, body mode, or review behavior.

Current policies can be deterministic source/intake/category rules. Later policies can use extracted article content and local LLM classification.

Output feed rules should remain additive until explicit excludes are introduced through later policy work.

### Pipeline Step Type

A pipeline step type is the conceptual operation being performed.

Examples:

- extraction
- digestion
- filtering
- rendering

### Pipeline Step Implementation

A pipeline step implementation is the concrete strategy for a step type.

Examples:

- `extraction.site_policy`
- `digestion.ollama.article_digest`
- `filtering.local_llm.topic_policy`

Implementations should be registered in code with metadata for labels, config schema, validation, and runtime behavior. The database should store selected implementation keys and config, not arbitrary executable behavior.

The output-scoped extraction implementation is `extraction.site_policy`. Simple HTML, headless browser, and headed browser are extractor strategies selected by host policy rather than independent output-feed pipeline choices.

## Pipeline Shape

```text
input feeds
  -> intake group
       fetch feeds
       store raw feed entries and raw parsed metadata
       dedupe related source feeds
       preserve source appearances
  -> article pool
       canonical article records
       extraction state
       classification state
       digest/newspaper state
  -> output feeds
       select articles from included intake groups and input feeds
       apply category/source rules
       apply optional future semantic policies
       render RSS
  -> FreshRSS
  -> Reeder
```

## Evaluation Model

Use eager evaluation and cached app-owned content.

When an input feed is fetched, the app should persist discovered raw items, resolve canonical articles, preserve source appearances, and create or update generated feed item records for eligible output feeds. Output feeds should render from generated feed item snapshots rather than directly from whatever is currently present in upstream source feeds or current article state.

This keeps output behavior stable when:

- upstream feeds rotate old items out
- input feeds are disabled
- output rules change
- article extraction later succeeds
- metadata is corrected

Retention and autopurge can be added later. Purging old content should be an explicit retention policy, not an accidental side effect of upstream feed churn.

## Feed Foundation

The feed foundation is:

```text
input feed configured
  -> intake group configured
  -> feed fetched
  -> raw item stored
  -> canonical article resolved within intake group
  -> source appearance recorded
  -> output feed eligibility determined by deterministic rules
  -> generated feed item record created or updated
  -> rendered RSS snapshot stored
  -> generated RSS published
```

Extraction, classification, article digestion, and semantic filtering should be added as explicit pipeline steps on top of this foundation.

## Configurable Processing Pipeline

Future processing capabilities should extend the output-feed pipeline rather than adding one-off execution paths.

The initial scope remains the output feed. This allows different generated feeds to enable extraction and choose filtering, digestion, and rendering behavior without changing source intake. Extractor selection itself remains host-scoped so one article is fetched consistently and its extraction artifact can be reused across outputs.

An enabled output-feed extraction step is the sole scheduling switch for extraction. New generated feed items automatically request extraction through that step. Enabling a step remains future-only; existing items require an explicit bulk extraction action. Link-to-hosted and extracted-body settings consume an available extraction artifact but do not independently schedule work.

Pipeline steps should have:

- scope
- step type
- implementation key
- position
- enabled flag
- config

Pipeline step attempts should record:

- article and generated feed item references when applicable
- parent run reference for bulk execution
- associated execution runs, including interrupted and repeated executions
- input snapshot
- output snapshot
- status
- error
- started and finished timestamps

Each generated feed item should snapshot its enabled step definitions, ordered state, exact artifact references, and latest attempt. This separates a feed's current configuration from the work previously requested for an item. Deleting a current definition must preserve item snapshots and attempt history.

Domain tables hold durable results. Attempt records explain how those results were produced. Extraction artifacts are article-level reusable state; digest artifacts are versioned and item steps reference the exact selected result. The output-feed step records why processing was requested, while site extraction policy and worker attempts record how extraction was performed.

Bulk processing should create a durable run before attempts are queued. The run owns aggregate progress and completion state; individual attempts remain the deterministic work history, and each execution run points back to its attempt. Enrollment belongs to an application-supervised dispatcher rather than the requesting LiveView or HTTP process. An unfinished parent batch must resume enrollment from its durable feed and step context after an application restart.

Queued pipeline attempts must also survive application restarts. Each step dispatcher should recover its own interrupted work by returning persisted `running` attempts to `queued`, closing the abandoned per-attempt diagnostic run as interrupted, and executing the attempt again from the beginning. Completed artifacts remain durable and reusable; an external HTTP or worker call is not resumed mid-request. Manual processing of existing items should skip articles with a successful current artifact unless the operator explicitly requests reprocessing.

Normal work created as new articles arrive should take priority over queued bulk processing. A running attempt should finish normally, then each dispatcher should select foreground work before older batch attempts. This priority is derivable from durable attempt ownership: attempts without a parent batch are foreground, while attempts attached to a bulk run are backfill work. Restart recovery must preserve the same ordering without requiring a separate in-memory-only priority flag.

## Extraction, Digestion, And Filtering

Content extraction comes before semantic filtering and article digestion. When both filtering and digestion are enabled, filtering should normally run first so excluded articles do not consume digest work. The first digest implementation produces a replacement title and summary together from the same extracted article and model call.

```text
article in pool
  -> extraction step attempted when enabled
  -> extracted article content stored
  -> filtering step attempted when enabled
  -> digestion step attempted for eligible articles when enabled
  -> structured digest title and summary stored
  -> output policies decide inclusion, exclusion, rendering, or review routing
```

Feed metadata can provide cheap hints, but content-aware filtering should rely on extracted article content when possible.

The digest implementation is `digestion.ollama.article_digest`. It calls a configured Ollama server directly, snapshots the globally selected discovered model for queued work, and stores versioned article artifacts referenced by generated feed item state. This is intentionally a Newspaper-specific article transform, not a general LLM workflow layer.

Extraction should use an app-owned escalation chain. The extractor implementations are separate executables with a shared contract, but the Elixir app decides which implementation to try, when to escalate, and what to remember for a site.

Initial extraction chain:

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

The app should store site-level extraction policy so future articles can skip extractors that are known not to work for that site. For example, if a site consistently requires a real logged-in browser session, future extraction should begin at the headed-browser implementation rather than wasting time on simple HTML or isolated headless rendering.

Workers should return normalized success, quality, and failure information. Failure kinds such as JavaScript required, auth required, paywall, blocking, or repeated insufficient content can trigger escalation. Network errors and timeouts should remain ordinary transient failures. The first simple-client rate limit should back off, honoring any explicit `Retry-After`. If Simple is rate-limited again on a later attempt, the same attempt should probe Headless because publishers can use `429` for bot classification. Explicit retry timing controls when the later attempt is allowed, not whether it may escalate. A headless rate limit must preserve adaptive backoff and must not automatically escalate into the persistent headed browser.

Extractor success means that a usable article body remains after shared structural and semantic boilerplate removal. Navigation, legal footers, related-link blocks, and other page chrome must not count toward extraction quality. An embedded-media page with no remaining article body returns terminal `insufficient_content` with a zero-length usable result, allowing the app to escalate extraction or skip downstream content-dependent steps. Legitimate short prose, structured schedules, and link-rich editorial text remain article content rather than being rejected by a prose-only heuristic. Workers should expose candidate length and removed-boilerplate measurements so quality decisions remain auditable.

An article URL can become stale while a publisher keeps the underlying post available at a corrected permalink. When a direct article request returns `404` or `410`, extraction may retry a URL-shaped feed stable ID only when it belongs to the same site. The redirect target becomes the resolved article URL after successful extraction. A missing article with no successful same-site fallback is a terminal, visible result: bulk processing should skip it, preserve the raw feed snapshot, and leave explicit manual retry available.

## Deduplication Boundary

Deduplication should focus on duplicates within an intake group, especially repeated articles published to multiple feeds from the same outlet.

Current dedupe should use normalized URL and feed-provided stable ID as its initial signals. The dedupe engine should be extensible, but title/date similarity, canonical link metadata from extracted pages, redirects, and semantic clustering should wait until real feed behavior shows they are needed.

Cross-outlet semantic clustering is a later capability. It may matter for the morning newspaper or World Radar, but it should not block feed-level dedupe.

When original pass-through rendering is selected, dedupe should select one representative raw entry for the generated feed item snapshot. The app does not need to merge duplicate item bodies.

Representative selection should use the earliest timestamp, with a deterministic arbitrary tie-break when needed. The exact duplicate winner is not product-critical because extraction is expected to become the meaningful content source; feed output mostly needs a usable article URL and stable identity.

Representative timestamp hierarchy:

1. earliest usable feed item `published_at`
2. fallback earliest usable feed item `updated_at`
3. fallback earliest `discovered_at`
4. fallback deterministic raw item ID/order

## Output Boundary

Output feeds are not responsible for discovering or deduplicating raw feed items. They select from the post-intake article pool.

An article may be eligible for multiple output feeds. Output-specific policies decide whether it is included, excluded, routed to review, or rendered with a particular body mode.

Output feed rendering should use durable generated feed item records and their rendered snapshots, not live recomputation from upstream source feed contents or current article state on every request.

If extraction or digestion succeeds, metadata is corrected, or title/body/link rendering policy changes, a deterministic re-render step should update stored generated feed item snapshots. Saving rendering policy is itself the explicit command to start a scoped re-render. The generated feed item GUID should remain stable.

Pipeline and membership configuration changes should apply to newly processed articles by default. Backfilling existing articles or rebuilding generated feed items should require explicit user action. Rendering policy is presentation rather than processing configuration, so saving it should refresh existing snapshots without generating new extraction or digestion artifacts.

Backfill and re-render are separate operations. Backfill creates missing generated feed item records from existing articles. Re-render updates stored RSS snapshots for existing generated feed items using app-owned stored data. Re-render may run automatically after rendering-policy changes or manually for recovery; it does not fetch upstream RSS, generate processing artifacts, mutate raw intake records, or change generated feed item GUIDs.

Each output feed should render a configurable rolling window of recent generated feed item snapshots. The default item limit is `500`.

## Output Feed Rule Model

Output feed membership should be represented natively rather than as an opaque JSON rule engine.

Supported inclusion rules:

- include an intake group
- include an individual input feed

Current rules are additive only. Explicit excludes should wait for later policy work.

Including an intake group means all enabled input feeds currently in that intake group, plus enabled input feeds added to that intake group later. Individual input feed inclusion exists for precision when an output feed should include only selected feeds from an intake group.

If a canonical article is eligible for an output feed through multiple included input feeds or intake groups, it should still create only one generated feed item for that output feed.
