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

Article records preserve source appearances, source metadata, stable app-generated article identity, extraction state, classification state, and later summary/newspaper metadata.

### Output Feed

An output feed is a generated RSS feed consumed by FreshRSS.

Output feeds select from the article pool. They are commonly category feeds, but the mechanism should be generic enough to support review feeds, source bundles, and later policy-filtered feeds.

Categorization, filtering, and routing belong primarily at the output-feed layer.

Output feeds also control RSS rendering settings such as whether item links point to original articles or hosted extracted article pages, and whether item bodies use original feed content or extracted content when available.

Output feeds should have stable app-generated identities for feed URLs and feed-level metadata. Generated feed items should also have stable app-generated identities and act as durable publication records.

### Policy

A policy controls output-feed eligibility, filtering, routing, body mode, or review behavior.

Current policies can be deterministic source/intake/category rules. Later policies can use extracted article content and local LLM classification.

Output feed rules should remain additive until explicit excludes are introduced through later policy work.

### Pipeline Step Type

A pipeline step type is the conceptual operation being performed.

Examples:

- extraction
- summarization
- filtering
- rendering

### Pipeline Step Implementation

A pipeline step implementation is the concrete strategy for a step type.

Examples:

- `extraction.site_policy`
- `summarization.local_llm.brief`
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
       summary/newspaper state
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

Extraction, classification, summarization, and semantic filtering should be added as explicit pipeline steps on top of this foundation.

## Configurable Processing Pipeline

Future processing capabilities should extend the output-feed pipeline rather than adding one-off execution paths.

The initial scope remains the output feed. This allows different generated feeds to enable extraction and choose filtering, summarization, and rendering behavior without changing source intake. Extractor selection itself remains host-scoped so one article is fetched consistently and its extraction artifact can be reused across outputs.

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
- input snapshot
- output snapshot
- status
- error
- started and finished timestamps

Domain tables hold durable current results. Attempt records explain how those results were produced. Extraction artifacts are article-level reusable state; the output-feed step records why processing was requested, while site extraction policy and worker attempts record how extraction was performed.

Bulk processing should create a durable run before attempts are queued. The run owns aggregate progress and completion state; individual attempts remain the deterministic execution history. Manual processing of existing items should skip articles with a successful current artifact unless the operator explicitly requests reprocessing.

## Extraction, Filtering, And Summarization

Content extraction comes before semantic filtering and summarization.

```text
article in pool
  -> extraction step attempted when enabled
  -> extracted article content stored
  -> filtering step attempted when enabled
  -> summarization step attempted when enabled
  -> output policies decide inclusion, exclusion, rendering, or review routing
```

Feed metadata can provide cheap hints, but content-aware filtering should rely on extracted article content when possible.

Extraction should use an app-owned escalation chain. The extractor implementations are separate executables with a shared contract, but the Elixir app decides which implementation to try, when to escalate, and what to remember for a site.

Initial extraction chain:

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

The app should store site-level extraction policy so future articles can skip extractors that are known not to work for that site. For example, if a site consistently requires a real logged-in browser session, future extraction should begin at the headed-browser implementation rather than wasting time on simple HTML or isolated headless rendering.

Workers should return normalized success, quality, and failure information. Failure kinds such as JavaScript required, auth required, paywall, blocking, or repeated insufficient content can trigger escalation. Network errors and timeouts should remain ordinary transient failures unless repeated real usage proves otherwise.

## Deduplication Boundary

Deduplication should focus on duplicates within an intake group, especially repeated articles published to multiple feeds from the same outlet.

Current dedupe should use normalized URL and feed-provided stable ID as its initial signals. The dedupe engine should be extensible, but title/date similarity, canonical link metadata from extracted pages, redirects, and semantic clustering should wait until real feed behavior shows they are needed.

Cross-outlet semantic clustering is a later capability. It may matter for the morning newspaper or World Radar, but it should not block feed-level dedupe.

In unprocessed/pass-through output, dedupe should select one representative raw entry for the generated feed item snapshot. The app does not need to merge duplicate item bodies.

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

If extraction succeeds, metadata is corrected, or output feed settings change, an explicit re-render/reprocess step should update the stored generated feed item snapshots. The generated feed item GUID should remain stable.

Configuration changes should apply to newly processed articles by default. Backfilling existing articles, rebuilding generated feed items, or re-rendering snapshots should require explicit user action.

Backfill and re-render are separate operations. Backfill creates missing generated feed item records from existing articles. Re-render updates stored RSS snapshots for existing generated feed items using app-owned stored data. Re-render does not fetch upstream RSS, mutate raw intake records, or change generated feed item GUIDs.

Each output feed should render a configurable rolling window of recent generated feed item snapshots. The default item limit is `500`.

## Output Feed Rule Model

Output feed membership should be represented natively rather than as an opaque JSON rule engine.

Supported inclusion rules:

- include an intake group
- include an individual input feed

Current rules are additive only. Explicit excludes should wait for later policy work.

Including an intake group means all enabled input feeds currently in that intake group, plus enabled input feeds added to that intake group later. Individual input feed inclusion exists for precision when an output feed should include only selected feeds from an intake group.

If a canonical article is eligible for an output feed through multiple included input feeds or intake groups, it should still create only one generated feed item for that output feed.
