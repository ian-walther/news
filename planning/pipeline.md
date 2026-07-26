# Pipeline Architecture

## Core Abstraction

The system has three distinct source and feed concepts:

- Outlets are real-world editorial identities, Article dedupe boundaries, and
  Newspaper source-vote units.
- Input Feeds are RSS or Atom discovery endpoints owned by an Outlet.
- Output Feeds are user-configured generated RSS products published to
  FreshRSS after selection, filtering, and rendering.

These concepts must not collapse into one generic grouping abstraction.

The pipeline should use eager durable intake, not lazy mirroring of current
upstream feed contents. Input Feeds are discovery endpoints. Once discovered,
Raw Items, canonical Articles, Article Appearances, extraction artifacts,
classifications, and generated feed items become app-owned durable records.

The app should store enough raw parsed feed data and later rendered metadata that it does not need to consult the original upstream feed entry after ingestion.

## Vocabulary

### Input Feed

An Input Feed is a raw RSS or Atom URL owned by one Outlet.

Examples:

- WSJ Technology
- WSJ Markets
- Ars Technica
- Local news feed

### Outlet

An Outlet is the required real-world editorial identity behind one or more
Input Feeds.

For example, one Wall Street Journal Outlet may own Technology, Markets, and
general-news Input Feeds. Repeated appearances across those feeds resolve to
one Outlet-specific canonical Article while preserving every Raw Item and
Article Appearance.

Deduplication belongs at the Outlet boundary. Each current ungrouped Input Feed
receives an Outlet during the semantic migration. Outlet is also the
Newspaper's source-vote and base-policy scope.

Related feeds are grouped for consumption by Output Feed membership. That use
case does not require a second Intake Group abstraction.

### Article Pool

The Article pool is the durable set of Outlet-specific canonical Articles.

Article records preserve Article Appearances, Outlet identity, stable
app-generated Article identity, extraction state, classification state, and
later digest and Newspaper relationships.

### Output Feed

An output feed is a generated RSS feed consumed by FreshRSS.

Output Feeds select from the Article pool. They are commonly category feeds,
but the mechanism should remain generic enough to support review feeds, Outlet
bundles, and policy-filtered feeds.

Categorization, filtering, and routing belong primarily at the output-feed layer.

Output feeds also control RSS rendering settings such as whether item links point to original articles or hosted extracted article pages, whether item titles use original or generated digest titles, and whether item bodies use original feed content, extracted content, or digest summaries.

Output feeds should have stable app-generated identities for feed URLs and feed-level metadata. Generated feed items should also have stable app-generated identities and act as durable publication records.

### Policy

A policy controls output-feed eligibility, filtering, routing, body mode, or review behavior.

Current policies can be deterministic Outlet, Input Feed, and category rules.
Later policies can evaluate app-owned Article classifications.

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

`extraction.site_policy` remains the coordinator implementation. Its target
scope is upstream Article enrichment policy rather than an Output Feed. Simple
HTML, headless browser, and headed browser remain strategies selected by host
policy rather than competing consumer choices. Existing output-scoped rows
remain compatibility history during migration.

## Pipeline Shape

```text
Outlets and Input Feeds
  -> Outlet intake boundary
       fetch feeds
       store raw feed entries and raw parsed metadata
       dedupe within one Outlet
       preserve Article Appearances
  -> shared Article pool
       canonical article records
       shared extraction artifacts
       app-owned classification artifacts
  -> Reading Feed path
       select Articles from included Outlets and Input Feeds
       apply category/source rules
       evaluate optional semantic policies
       optionally digest for feed presentation
       render RSS
       publish to FreshRSS and Reeder
  -> Newspaper path
       cluster cross-Outlet Events
       apply weighted admission and placement
       extract Claims and evidence
       synthesize and cite
       publish immutable hosted Editions
```

## Evaluation Model

Use eager evaluation and cached app-owned content.

When an Input Feed is fetched, the app should persist discovered Raw Items,
resolve Outlet-specific canonical Articles, preserve Article Appearances, and
create or update generated feed item records for eligible Output Feeds.
Upstream enrichment should then produce reusable extraction and classification
artifacts independent of Output Feed membership. Output Feeds should render
from generated feed item snapshots rather than directly from mutable upstream
or Article state.

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
Outlet and Input Feed configured
  -> feed fetched
  -> raw item stored
  -> canonical Article resolved within its Outlet boundary
  -> Article Appearance recorded
  -> shared extraction and classification requested by upstream policy
  -> Output Feed and Newspaper eligibility evaluated independently
  -> generated feed item record created or updated
  -> rendered RSS snapshot stored
  -> generated RSS published
```

Extraction and Article classification are shared upstream steps. Article
digestion, output-specific filtering, and rendering remain downstream
consumer steps. Newspaper clustering, evidence analysis, synthesis, and
Edition rendering form a second downstream path over the same enriched corpus.

## Configurable Processing Pipeline

Processing capabilities should use one code-owned registry and durable attempt
model while allowing the correct domain scope for each operation.

- Outlet and Input Feed policies request shared Article extraction and
  classification.
- Host policy selects the extraction starting strategy and escalation path.
- Output Feeds configure output-specific filtering, digestion, and rendering.
- Newspaper configs schedule clustering, admission, evidence analysis,
  synthesis, Edition rendering, and delivery.

Existing output-scoped extraction history must remain valid during migration,
but new extraction demand should move upstream. A shared Article extraction is
produced once and reused by every Output Feed and Newspaper run that references
it.

Enabling upstream enrichment remains future-only by default. Existing Articles
require an explicit scoped backfill. Output link, title, body, and hosted-page
settings consume available artifacts but do not independently create competing
extractions.

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

Each generated feed item should snapshot its enabled output-specific step
definitions, ordered state, exact shared artifact references, and latest
attempt. Edition manifests provide the equivalent immutable snapshot for the
Newspaper. Deleting a current definition must preserve historical snapshots
and attempt history.

Domain tables hold durable results. Attempt records explain how those results
were produced. Extraction and classification artifacts are Article-level
reusable state; digest and synthesis artifacts are versioned and consumers
reference the exact selected result. Demand policy records why processing was
requested, while site policy and worker attempts record how extraction ran.

Bulk processing should create a durable run before attempts are queued. The run owns aggregate progress and completion state; individual attempts remain the deterministic work history, and each execution run points back to its attempt. Enrollment belongs to an application-supervised dispatcher rather than the requesting LiveView or HTTP process. An unfinished parent batch must resume enrollment from its durable feed and step context after an application restart.

Queued pipeline attempts must also survive application restarts. Each step dispatcher should recover its own interrupted work by returning persisted `running` attempts to `queued`, closing the abandoned per-attempt diagnostic run as interrupted, and executing the attempt again from the beginning. Completed artifacts remain durable and reusable; an external HTTP or worker call is not resumed mid-request. Manual processing of existing items should skip articles with a successful current artifact unless the operator explicitly requests reprocessing.

Normal work created as new articles arrive should take priority over queued bulk processing. A running attempt should finish normally, then each dispatcher should select foreground work before older batch attempts. This priority is derivable from durable attempt ownership: attempts without a parent batch are foreground, while attempts attached to a bulk run are backfill work. Restart recovery must preserve the same ordering without requiring a separate in-memory-only priority flag.

## Extraction, Classification, Digestion, And Filtering

Content extraction precedes app-owned Article classification. Downstream
consumers evaluate their policies against the shared classification. The
Reading Feed may then produce a single-Article digest for eligible items; the
Newspaper clusters Articles before Claim extraction and cross-source
synthesis.

```text
article in pool
  -> upstream extraction requested when enabled
  -> extracted article content stored
  -> Article classification stored
  -> Reading Feed policies decide inclusion, exclusion, or review
       -> optional Article digest
       -> RSS rendering
  -> Newspaper policy admits and clusters Events
       -> Claim and evidence analysis
       -> synthesized Edition Story
```

Feed metadata can provide cheap hints, but content-aware classification should
rely on extracted Article content when possible. Output-specific filtering
should normally reuse classification rather than issuing another unconstrained
classification call.

The digest implementation is `digestion.ollama.article_digest`. It calls a
configured Ollama server directly, snapshots the globally selected discovered
model for queued work, and stores versioned Article artifacts referenced by
generated feed item state. This is a bounded Reading Feed transform, not the
cross-source Newspaper synthesizer or a general LLM workflow layer.

Extraction should use an app-owned escalation chain. The extractor implementations are separate executables with a shared contract, but the Elixir app decides which implementation to try, when to escalate, and what to remember for a site.

Extractor chain:

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

The app should store site-level extraction policy so future articles can skip extractors that are known not to work for that site. For example, if a site consistently requires a real logged-in browser session, future extraction should begin at the headed-browser implementation rather than wasting time on simple HTML or isolated headless rendering.

Workers should return normalized success, no-content, quality, and failure information. Concrete outcomes include rate limited, not found, blocked, unsupported content type, timeout, network error, generic HTTP or browser failure, auth required, and paywall. The headed worker identifies authentication barriers only from deterministic login redirects or explicit access-barrier copy; it does not infer auth failure merely because a page contains ordinary sign-in navigation. Auth and browser-availability failures stay visible and manually retryable. A no-content result from a lower-capability extractor also triggers escalation. Network errors and timeouts should remain ordinary transient failures. A retryable rate limit should create a durable queued attempt so site backoff, process restarts, and later site recovery cannot strand the article in a failed state. Automatic retries should have a finite budget; exhausting it leaves a visible, manually retryable failure. The first simple-client rate limit should back off, honoring any explicit `Retry-After`. If Simple is rate-limited again on a later attempt, the same attempt should probe Headless because publishers can use `429` for bot classification. Explicit retry timing controls when the later attempt is allowed, not whether it may escalate. A headless rate limit must preserve adaptive backoff and must not automatically escalate into the persistent headed browser.

Extractor success means that a usable article body remains after shared structural and semantic boilerplate removal. Navigation, legal footers, related-link blocks, executable media embeds, player chrome, and other page furniture must not count toward extraction quality. Embed cleanup should remove narrowly identified low-prose media containers and explicit fallback instructions while preserving ordinary editorial figures and surrounding prose. The site policy's minimum text length is a strict floor applied to the cleaned article body; sites that publish legitimate shorter material should use a lower site-specific minimum. An embedded-media page with no remaining article body returns `no_content` with a zero-length usable result. The app escalates when another extractor is available; a terminal no-content result is a valid skipped outcome, creates no failure record, and skips downstream content-dependent steps. A later successful re-extraction reactivates those skipped steps through normal pipeline advancement. Legitimate short prose, structured schedules, and link-rich editorial text remain article content when they satisfy the configured floor rather than being rejected by a prose-only heuristic. Workers should expose candidate length plus removed-boilerplate and embedded-media measurements so quality decisions remain auditable.

An article URL can become stale while a publisher keeps the underlying post available at a corrected permalink. When a direct article request returns `404` or `410`, extraction may retry a URL-shaped feed stable ID only when it belongs to the same site. The redirect target becomes the resolved article URL after successful extraction. A missing article with no successful same-site fallback is a terminal, visible result: bulk processing should skip it, preserve the raw feed snapshot, and leave explicit manual retry available.

## Deduplication Boundary

Article deduplication occurs within one Outlet. It catches repeated publication
of the same Article through several Input Feeds owned by that Outlet while
preserving every Article Appearance.

Current dedupe should use normalized URL and feed-provided stable ID as its initial signals. The dedupe engine should be extensible, but title/date similarity, canonical link metadata from extracted pages, redirects, and semantic clustering should wait until real feed behavior shows they are needed.

Cross-Outlet similarity is Event clustering, not Article deduplication.
Syndication and common-origin relationships remain explicit so the Newspaper
can distinguish coverage breadth from evidentiary independence.

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

Hosted article presentation is also output-feed-specific. A hosted RSS link
should carry the stable output-feed identity as presentation context so the
same canonical article can show its selected digest for one output feed and
omit it for another. The page should use the successful digest artifact
referenced by that generated feed item's digestion state rather than choosing
an unrelated globally latest digest.

Pipeline and membership configuration changes should apply to newly processed articles by default. Backfilling existing articles or rebuilding generated feed items should require explicit user action. Rendering policy is presentation rather than processing configuration, so saving it should refresh existing snapshots without generating new extraction or digestion artifacts.

Backfill and re-render are separate operations. Backfill creates missing generated feed item records from existing articles. Re-render updates stored RSS snapshots for existing generated feed items using app-owned stored data. Re-render may run automatically after rendering-policy changes or manually for recovery; it does not fetch upstream RSS, generate processing artifacts, mutate raw intake records, or change generated feed item GUIDs.

Each output feed should render a configurable rolling window of recent generated feed item snapshots. The default item limit is `500`.

## Output Feed Rule Model

Output feed membership should be represented natively rather than as an opaque JSON rule engine.

Supported inclusion rules:

- include an Outlet
- include an individual Input Feed

Current rules are additive only. Explicit excludes should wait for later policy work.

Including an Outlet means all enabled Input Feeds currently owned by that
Outlet, plus enabled Input Feeds added to it later. Individual Input Feed
inclusion provides precision when an Output Feed should include only selected
feeds from an Outlet.

If a canonical Article is eligible for an Output Feed through several
memberships or Article Appearances, it still creates only one generated feed
item for that Output Feed.
