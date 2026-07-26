# Newspaper Domain Model

## Direction

The application is becoming an opinionated news product. Its durable model
should encode the real-world concepts the Newspaper depends on instead of
asking generic grouping abstractions to carry incompatible meanings.

The target flow is:

```text
Outlet
  -> Input Feeds
  -> Raw Items
  -> outlet-scoped canonical Articles
  -> extraction and app-owned classification
  -> shared Article corpus
       -> Reading Feed selection and rendering
       -> cross-Outlet Event clustering
            -> Story Threads
            -> Newspaper admission and synthesis
            -> immutable Editions
```

## Core Source Concepts

### Outlet

An Outlet is the real-world editorial or publishing identity responsible for
an Article.

It is:

- the required parent of one or more Input Feeds
- the deduplication boundary for Articles appearing through several feeds from
  the same publisher
- the source-vote unit for Newspaper breadth and prominence
- the base scope for trust, topic, section, Local, and participation policy
- the identity shown in provenance and coverage lists

Use **Outlet**, not **Publisher**, because publisher may also mean a corporate
owner spanning several editorially distinct publications.

### Input Feed

An Input Feed is one RSS or Atom discovery endpoint owned by an Outlet.

It owns endpoint concerns:

- feed URL and display name
- enabled state and fetch cadence
- HTTP validators and fetch status
- upstream categories or metadata hints
- optional feed-specific policy overrides

Input Feed membership does not define Article truth, section placement, or
Reading Feed grouping.

### Output Feed

An Output Feed is a user-configured generated RSS product.

It may include:

- all enabled Input Feeds from one or more Outlets
- selected individual Input Feeds
- later classification or routing policies

Output Feed membership answers where the user wants to read an Article. It
does not define who published it, how it is deduplicated, or whether it
participates in the Newspaper.

### Article Appearance

An Article Appearance records that one canonical Article was discovered in one
Input Feed through one Raw Item.

It preserves:

- Article, Input Feed, and Raw Item identities
- first-seen time
- feed-provided categories and metadata
- discovery and attribution evidence

The current `ArticleSource` name is misleading because the row is a discovery
mapping rather than the editorial source itself.

## Article and Event Concepts

### Article

An Article is one Outlet-specific canonical publication. Canonicalization
collapses repeated appearances and stable identifiers within the Outlet
boundary.

Articles from different Outlets remain distinct even when syndicated or
substantially similar. Reporting dependencies and syndication origins are
modeled explicitly rather than cross-Outlet deduplication destroying
provenance.

### Article Extraction

An Article Extraction is a versioned or revision-addressable content artifact
derived from an Article URL. It is shared across every downstream consumer.

Extraction must not require Output Feed membership. An Article can be
Newspaper-only and still require extraction.

### Article Classification

An Article Classification is an app-owned artifact derived from extracted
content and metadata.

It should preserve:

- taxonomy and label assignments
- section and topic candidates
- geographic relevance
- confidence and rationale
- model, prompt, schema, and input revision
- review or correction state where needed

Upstream feed categories and sub-feed membership are hints or priors, not
authoritative classification. The application classifies the Article itself.

### Event

An Event is a cross-Outlet cluster of Articles covering the same underlying
occurrence or tightly connected development.

It preserves:

- member Articles
- clustering evidence and implementation version
- earliest/latest occurrence, publication, and discovery times
- candidate section, topics, entities, and geography
- known syndication or reporting-dependency relationships
- operator merge/split audit history

Event identity must survive routine reprocessing. Cluster corrections should
change explicit relationships rather than silently rewriting historical
Edition inputs.

### Story Thread

A Story Thread links related Events across time for backstory and continuity.
It begins Active, becomes Dormant after a configurable inactivity period, and
reactivates automatically. It is not a replacement for Event identity.

### Claim and Evidence

A Claim is an assertion used by synthesis. Claim Evidence links a Claim to an
Article, primary document, statement, or another traceable source location and
describes support, contradiction, attribution, independence, and interest.

The minimal vocabulary is finalized before the Claim tables land; the data
model must allow source-specific evidence without storing model chain of
thought.

## Edition Concepts

### Edition

An Edition is an immutable scheduled publication artifact.

It stores:

- content cutoff, delivery deadline, and timezone
- sealed generation manifest
- taxonomy, policy, weight, model, prompt, schema, and implementation versions
- generation status and phase metrics
- publication and delivery timestamps
- stable hosted identity

An Edition with at least one complete valid story may publish. Zero completed
stories produces a failed run and failure notification.

### Edition Story

An Edition Story is the immutable rendered snapshot of one synthesized story
within an Edition.

It stores:

- Event and optional Story Thread references
- headline, compact summary, and full prose snapshots
- primary section and secondary tags
- coverage-source snapshot
- citation and provenance snapshot
- Story So Far snapshot when present
- ordering and rendering metadata

Later configuration or Article changes do not rewrite it.

### Correction

A Correction links a later correction, clarification, or retraction to the
affected Edition Story and Claim while preserving the original artifact.

### Delivery Attempt

A Delivery Attempt records email delivery or failure independently from
Edition generation. Retrying delivery must not regenerate or mutate the
Edition.

## Processing Boundaries

Fetching, canonicalization, extraction, and Article classification belong
upstream of outputs:

```text
ingestion
  -> canonical Article
  -> extraction
  -> classification
  -> shared enriched corpus
```

Downstream consumers then apply their own policies:

```text
shared enriched corpus
  -> Output Feed membership/filter/render decisions
  -> Newspaper clustering/admission/synthesis
```

Feed metadata remains useful as a cheap hint. It cannot be the only source of
classification because:

- Outlets organize sub-feeds inconsistently
- one Article may appear in several sub-feeds
- source categories do not match the user's taxonomy
- source-specific Topic weights require consistent app-owned labels
- Newspaper-only sources may have no Output Feed membership

## Semantic Migration from the Current Schema

The first expansion phase should perform explicit, data-preserving semantic
migrations:

| Current concept | Target concept |
| --- | --- |
| `IntakeGroup` / `intake_groups` | `Outlet` / `outlets` |
| `InputFeed.intake_group_id` | required `InputFeed.outlet_id` |
| `InputFeed.outlet_name` and copied outlet strings | relationship-backed Outlet identity plus historical snapshots where required |
| `ArticleSource` / `article_sources` | `ArticleAppearance` / `article_appearances` |
| `generated_feed_intake_groups` | `generated_feed_outlets` |
| ungrouped Input Feed dedupe boundary | a required Outlet, created during migration |
| output-scoped extraction scheduling | upstream Article enrichment policy |
| feed-category classification | app-owned Article Classification with feed metadata as evidence |

The migration must preserve:

- every current Input Feed
- every canonical Article and stable Article identifier
- every Raw Item and appearance relationship
- every dedupe key
- every generated Output Feed and stable feed identifier
- every generated feed item and RSS GUID
- existing extraction, digest, attempt, run, and render history

The migration may temporarily retain compatibility fields or aliases, but the
operator vocabulary and target schema should converge on Outlet, Input Feed,
Output Feed, and Article Appearance rather than maintaining two permanent
models for the same concept.

