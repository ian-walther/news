# Newspaper Product Contract

## Purpose

The Newspaper should turn a large user-configured source universe into a clean
daily account of what happened. It is not an article summarizer and does not
claim to manufacture perfect neutrality. It should separate factual reporting
from framing, opinion, speculation, and interested-party claims while keeping
the evidence visible enough to audit.

The product should help the reader:

- understand the major events covered by configured sources
- ignore stories that are not interesting without losing the rest of the
  edition
- open a coherent article when a story is interesting
- recover concise backstory without rereading yesterday's coverage
- inspect citations, prior coverage, timelines, and source provenance when
  desired

Personalization comes from explicit source, weight, topic, section, geographic,
and output configuration. Reading history is not used to mutate edition
content.

## Two Reading Products

### Reading Feed

The Reading Feed is the existing generated-RSS product. It is continuously
updating and article-centric.

It should retain:

- singleton reporting and niche articles
- essays, analysis, reviews, blogs, and entertaining pieces that are not
  event clusters
- national articles from a source whose Newspaper participation is restricted
  to Local coverage
- articles from sources enabled for RSS but disabled for Newspaper

The normal interaction is scanning headlines and opening the original or
hosted article.

### Newspaper

The Newspaper is scheduled and event-centric. It clusters coverage of the same
underlying event across independent configured Outlets, decides whether the
event merits inclusion, and produces a new factual article from the available
reporting and evidence.

The Newspaper and Reading Feed share one upstream article corpus. A source can
participate in either product, both products, or neither output while remaining
configured for ingestion.

## Hosted-First Delivery

The first Newspaper output is a hosted webpage optimized for tablet reading on
the trusted LAN or through the private-network access path.

The delivery email should remain lightweight:

- edition date
- section and headline overview
- direct link to the hosted edition
- clear failure notice when no valid edition was produced

An iPad-friendly PDF may be generated later as a secondary or vanity format.
Emailing a PDF, printing, and print-oriented layout must not delay the hosted
edition.

## Front Page

Each front-page story should contain:

- a neutral descriptive headline
- one compact factual paragraph
- the Outlets that covered the event
- a clear path to the full synthesized article

The coverage-source list communicates breadth. It does not imply that every
listed Outlet independently supports every sentence. Claim-level support
belongs in citations and provenance.

## Full Article

The full story should read like a clean newspaper article in coherent
paragraph-form prose. The default experience is not a bullet dossier, fact
table, or source-by-source recap.

The reading layers are:

1. Front-page headline, compact summary, and coverage-source list.
2. Synthesized newspaper article.
3. Optional evidence and history: numbered citations, exact sources, prior
   editions, event timeline, and deeper provenance.

Article length is derived from the event and available reporting. Neither
stories nor editions have a fixed word count, page count, section quota, or
target reading time.

## Sections and Tags

The initial controlled primary-section vocabulary is:

- World
- United States
- Local
- Business
- Finance & Markets
- Technology
- Science
- Health
- Environment & Energy
- Sports
- Automotive
- Arts & Culture
- Entertainment

Each story receives one primary section for placement and zero or more
secondary tags. Politics is a tag rather than a top-level section; political
stories remain placed under the geographic or subject section they directly
belong to.

A story appears once under its primary section. Secondary tags support
filtering, navigation, source policy, and Topic weighting without duplicating
the story across the Edition.

The initial controlled cross-cutting tags are:

- Politics
- Elections
- Courts
- Regulation
- Economy
- Labor
- Education
- Public Safety
- National Security
- Climate
- Space
- Artificial Intelligence
- Gaming
- Real Estate
- Media

Longform, opinion, lifestyle, food, and travel initially remain Reading Feed
categories because they describe an Article form or interest more often than a
cluster of developing Events.

Corrections is a reserved Edition section for later corrections,
clarifications, and retractions. It is not an ordinary primary classification
assigned to current Events.

Sections have stable internal identifiers and configurable labels, visibility,
and order. The initial vocabulary is intentionally editable through data and
configuration rather than hard-coded across the system. Used terms are
retired, renamed, aliased, merged, or split rather than destructively deleted.
Those changes must not require invasive rewrites or alter historical Edition
snapshots.

Empty sections may disappear from an edition.

## Stable Daily Editions

Each edition is a stable artifact defined by its configured reporting window,
not by which articles the reader previously opened.

- Old editions remain browsable.
- Later developments belong in later editions.
- Published editions are never silently rewritten.
- Corrections, clarifications, and retractions appear in a later edition and
  link back to the affected edition and story.
- A correction record may explain what changed without replacing the original
  artifact.

The main story body should emphasize developments since the preceding edition.
When continuity matters, the article may include **The Story So Far**:

- one visible sentence giving the minimum context
- a collapsed concise backstory
- links to relevant prior editions or timeline entries

The system does not track whether the reader personally consumed earlier
coverage.

## Scheduling and Hard Deadline

Each Newspaper configuration has two independent scheduled boundaries:

- **Content cutoff:** freezes the eligible input snapshot.
- **Delivery deadline:** seals the completed edition and sends the delivery
  email.

The gap is an explicit processing window for extraction, classification,
clustering, evidence analysis, synthesis, citation validation, and rendering.

The deadline is hard:

- publication and delivery occur automatically without manual review
- complete valid stories publish on time
- incomplete or invalid stories are omitted
- one failed source, extraction, cluster, or synthesis does not block the
  edition
- late work rolls into the next edition rather than changing the sealed one
- zero completed stories records a failed edition run and sends a failure
  notification instead of publishing an empty or recycled edition

No minimum story or section count exists beyond at least one completed valid
story.

The system should record total and phase-level processing duration, queue
depth, story counts through each phase, failures, timeouts, recent percentiles,
and remaining deadline margin. The UI may recommend an earlier cutoff when
recent runs consume too much of the window, but the user controls both times.

## Deterministic Generation

An edition is generated from a sealed manifest. It is not a mutable editorial
draft.

The manifest should identify:

- eligible Article and extraction revisions
- effective source policies and weights
- taxonomy version
- Event and Story Thread inputs
- model, prompt, and output-schema versions
- cutoff, deadline, and timezone
- processing implementation versions

Operators can inspect why an output occurred and retry failed work against the
same snapshot. They cannot manually edit clusters, prose, section placement,
citations, or story selection in place. Configuration changes affect future
runs. Published errors use the correction process.

## Initial Input Scope

The first Newspaper uses ordinary configured RSS and Atom Input Feeds plus the
existing extraction capabilities. The prerequisite is moving extraction and
classification upstream so configured feeds can enrich the shared Article
pool without requiring Output Feed membership.

The following are desired but deferred:

- Twitter-specific ingestion
- newsletter and mailbox ingestion
- unrestricted automatic discovery of official statements or press releases
- automatic subscription discovery
- PDF and print delivery
- supplemental editions for extraordinary late-breaking events

Known official feeds, agency pages, press-release feeds, newsletters, or social
accounts can later attach to the same Outlet and evidence model without
changing the core Newspaper contract.
