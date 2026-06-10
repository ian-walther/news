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

V1 policies can be deterministic source/intake/category rules. Later policies can use extracted article content and local LLM classification.

V1 output feed rules should be additive-only. Output feeds can include whole intake groups and/or individual input feeds. Excludes should wait for later policy work.

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

## V1 Pipeline

V1 should implement the feed-only version:

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

V1 does not require extraction, classification, summarization, or semantic filtering.

## Later Extraction And Filtering

Content extraction comes before semantic filtering.

```text
article in pool
  -> extraction attempted when enabled
  -> extracted article content stored
  -> local LLM classification/filtering attempted when enabled
  -> output policies decide inclusion, exclusion, or review routing
```

Feed metadata can provide cheap hints, but content-aware filtering should rely on extracted article content when possible.

## Deduplication Boundary

V1 deduplication should focus on duplicates within an intake group, especially repeated articles published to multiple feeds from the same outlet.

V1 dedupe should use normalized URL and feed-provided stable ID as its initial signals. The dedupe engine should be extensible, but title/date similarity, canonical link metadata from extracted pages, redirects, and semantic clustering should wait until real feed behavior shows they are needed.

Cross-outlet semantic clustering is a later capability. It may matter for the morning newspaper or World Radar, but it should not be treated as required V1 feed dedupe.

In unprocessed/pass-through output, dedupe should select one representative raw entry for the generated feed item snapshot. V1 does not need to merge duplicate item bodies.

Representative selection should use the earliest timestamp, with a deterministic arbitrary tie-break when needed. The exact duplicate winner is not product-critical because extraction is expected to become the meaningful content source later; V1 mostly needs a usable article URL and stable identity.

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

Each output feed should render a configurable rolling window of recent generated feed item snapshots. V1 default item limit is `500`.

## V1 Output Feed Rule Model

V1 output feed membership should be represented natively rather than as an opaque JSON rule engine.

Supported V1 inclusion rules:

- include an intake group
- include an individual input feed

V1 rules are additive only. There are no explicit excludes in V1.

Including an intake group means all enabled input feeds currently in that intake group, plus enabled input feeds added to that intake group later. Individual input feed inclusion exists for precision when an output feed should include only selected feeds from an intake group.

If a canonical article is eligible for an output feed through multiple included input feeds or intake groups, it should still create only one generated feed item for that output feed.
