# Open Questions

These are unresolved decisions that remain relevant to future implementation.
Settled Newspaper decisions belong in
[`planning/newspaper/`](newspaper/README.md), not in this list.

## Before Claims and Evidence

- What is the smallest useful Claim-type vocabulary?
- Which evidence relationships are required initially: support,
  contradiction, qualification, attribution, or another bounded set?
- How should observation, allegation, denial, estimate, prediction, opinion,
  and primary-record fact map onto Claim or source-role fields?
- How should interested-party status and evidentiary independence be
  represented?
- How should partial support from a primary document affect one Claim without
  becoming a generic Event-level vote?
- What source-location data must a Citation preserve for durable audit?

## Before Event Clustering

- Which deterministic similarity and named-entity signals should generate the
  first candidate clusters?
- When do embeddings materially improve on TF-IDF/n-grams for the configured
  corpus?
- How should likely syndication, citation chains, and common reporting origins
  be detected and represented?
- What initial inactivity duration moves a Story Thread from Active to
  Dormant?
- What is the smallest safe merge/split correction workflow and audit record?
- Which deterministic rule chooses a primary Section when several apply?

## Before Hosted Editions

- What default timezone, content cutoff, and delivery deadline should the first
  Newspaper configuration present?
- What stable LAN route shape should Edition archives use?
- What exact operator workflow creates a correction, clarification, or
  retraction after publication?
- Which email delivery mechanism should the first implementation use?

## Source and Policy UI

- What numeric range and increments should the weight controls permit?
- Should configured Sections beyond Local eventually have distinct admission
  thresholds?
- What compact UI best explains Outlet defaults, Input Feed overrides, Topic
  rules, Local rules, inheritance, exclusions, and effective weights?
- How should multiple localities and locality-specific source policies appear
  in the UI?

## Reading Feed Semantics

- How much source metadata should be visible in a generated feed body?
- When should explicit Output Feed excludes be introduced?
- Are there source-specific metadata fields that deserve dedicated storage
  beyond the complete Raw Item snapshot?
- What summary length and paragraph shape work best in Reeder?
- What prompt and validation bounds reliably produce a factual one-sentence
  digest title without clickbait?
- Which connection, model, and structured-output failures should retry
  automatically?

## Deduplication

- Which URL parameters should always be stripped?
- When should title/date similarity override different URLs within one Outlet?
- Which feed-provided ID patterns are reliable across Input Feeds from one
  Outlet?
- How should ambiguous same-Outlet dedupe matches be reviewed?

Cross-Outlet similarity is Event clustering rather than Article
deduplication.

## Retention and Rebuild

- How long should Raw Items, Articles, generated feed items, and verbose run
  history be retained by default?
- Should ordinary retention use age, item count, output membership, or a mix?
- Which extraction and classification revisions may be removed when nothing
  references them?
- How should immutable Editions, Citations, corrections, stable RSS identity,
  and their referenced artifacts be protected from autopurge?
- Should full rebuild remain a danger-zone action?
- If added, should rebuild scope by Output Feed, Outlet, Input Feed, Newspaper,
  date range, item count, or a mix?

## Workflow and Operations

- Which failure types eventually justify a first-class queue beyond the
  existing visible failure records?
- Which failure lifecycle states are justified by observed use?
- When, if ever, does the job surface justify moving from supervised processes
  to Oban or another Postgres-backed job system?
- How much implementation config should be typed fields versus validated raw
  JSON?
- How long should pipeline attempts be retained?

## Hosting and Production

- Which future services should run in Docker and which should stay on the host
  beside the persistent Chrome stack?
- Which persistent volumes will be needed outside Postgres?
- How should backup, restore, logs, and upgrades evolve as immutable Edition
  history grows?

## Deferred Product Expansion

- Should extraordinary late-breaking events ever create supplemental Editions?
- How should curated official-source discovery be bounded and verified?
- Which Twitter, newsletter, or mailbox ingestion path should be attempted
  first?
- When is PDF useful enough to add as a secondary Edition format?
- Which MQTT entities and Home Assistant controls become useful after hosted
  Editions and delivery are reliable?
