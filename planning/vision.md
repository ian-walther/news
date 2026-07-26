# Personal News System

## Purpose

Build a local-first personal news system that owns source intake, durable
Article state, extraction, classification, generated RSS, cross-source Event
understanding, and scheduled Newspaper publishing.

The application should reverse the usual incentives of online news: remove
clickbait, rhetorical inflation, repetition, and avoidable editorial framing
while preserving useful facts, uncertainty, disagreement, and provenance.

## Product Architecture

One configured source universe feeds a shared enriched Article corpus and two
complementary products:

```text
Outlets and Input Feeds
  -> fetch, canonicalize, extract, and classify
  -> shared Article corpus
       -> Reading Feed
       -> Newspaper
```

### Reading Feed

The Reading Feed is continuously updating and Article-centric. Generated
Output Feeds remain useful through FreshRSS and Reeder for scanning singleton
reporting, niche pieces, essays, analysis, reviews, blogs, and other worthwhile
Articles that do not need cross-source synthesis.

Output Feeds select from app-owned Article records and render stable RSS
snapshots. They independently control membership, filtering, title source,
body source, and original versus hosted links.

### Newspaper

The Newspaper is scheduled and Event-centric. It identifies important Events
through configurable weighted coverage across eligible Outlets, then creates
neutral synthesized prose with claim-level citations, visible uncertainty,
and optional backstory.

Each daily Edition is an immutable hosted artifact. A lightweight email
delivers the Edition link by a hard deadline. PDF and print output are later
formats, not prerequisites.

See [`planning/newspaper/`](newspaper/README.md) for the complete product,
source, editorial, and domain contracts.

## Core Domain Boundaries

- **Outlet:** the real-world editorial identity, Article dedupe boundary,
  Newspaper vote unit, and base policy scope.
- **Input Feed:** an RSS or Atom discovery endpoint owned by an Outlet.
- **Article Appearance:** the record that one Article appeared in one Input
  Feed through one Raw Item.
- **Output Feed:** a user-defined generated RSS destination; it groups reading
  material rather than defining source identity.
- **Article:** one Outlet-specific canonical publication.
- **Event:** a cross-Outlet cluster about one occurrence or development.
- **Story Thread:** continuity across related Events and Editions.
- **Edition:** a sealed scheduled publication artifact.

The previous optional Intake Group abstraction should migrate to the required
Outlet domain concept. Related Input Feeds are grouped for consumption through
Output Feed membership, while Outlet membership provides source identity and
deduplication.

## Processing Direction

Fetching, canonicalization, extraction, and app-owned Article classification
belong upstream of both products. Output Feed membership must not be required
to extract or classify an Article.

Feed categories and sub-feed membership are useful metadata hints, but the
application owns durable topic, section, geographic, and policy
classifications.

Conventional processing should narrow the problem before expensive model work:

```text
normalize and extract
  -> deterministic metadata and information-retrieval signals
  -> classify and cluster
  -> extract Claims and evidence relationships
  -> synthesize with provenance
```

LLMs are bounded transforms and editors, not the owner of durable state or the
entire pipeline.

## Guiding Principles

- Keep the Reading Feed valuable independently from the Newspaper.
- Keep source identity, discovery endpoints, and output membership separate.
- Preserve stable Article, Output Feed, feed-item, Event, and Edition
  identities.
- Use eager durable processing rather than live recomputation during RSS or
  Edition requests.
- Make weights, policies, classifications, failures, and generated artifacts
  explainable.
- Separate story prominence from factual confidence.
- Preserve immutable Editions and publish later corrections instead of silent
  rewrites.
- Make configuration explicit rather than inferring preferences from reading
  history.
- Prefer conventional compute before model calls when it can reliably narrow
  or structure the work.
- Keep the Phoenix application as the owner of orchestration and durable state;
  workers remain replaceable transforms with explicit contracts.
- Prefer observable partial failure over silent omission.
- Keep planning implementation-agent-agnostic.

## Initial Expansion Boundary

The first Newspaper expansion uses configured RSS and Atom feeds plus existing
extraction capabilities. It begins with the Outlet migration and moving
extraction/classification upstream.

Twitter-specific ingestion, newsletter ingestion, unrestricted official-source
discovery, PDF, print, supplemental Editions, and Home Assistant delivery
controls remain later work.
