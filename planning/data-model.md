# Target Data Model

## Direction

Use Postgres as the only supported durable store. The application owns feed
history, source identity, Article state, appearances, extraction and
classification artifacts, generated RSS publication, Event clustering,
evidence relationships, immutable Editions, run history, and failures.

This is a forward-looking schema contract rather than a final migration file.
The model should support eager durable processing and deterministic
reproduction without consulting upstream feeds or mutable model configuration
at read time.

See [`planning/newspaper/domain-model.md`](newspaper/domain-model.md) for the
semantic definitions behind these tables.

## Source and Article Tables

### `outlets`

Required real-world editorial identities and Article dedupe boundaries.

- stable application identifier
- display name
- enabled state
- base Newspaper participation policy and base weight, initially `1.0`
- source-role metadata
- default section, Topic, and Local policy references where configured
- dedupe strategy/configuration
- notes
- timestamps

One Outlet can own many Input Feeds. One Outlet contributes at most one source
vote to one Event regardless of how many of its feeds carried the Article.

### `input_feeds`

RSS or Atom discovery endpoints owned by an Outlet.

- stable application identifier
- required Outlet ID
- feed URL and display name
- enabled state
- fetch cadence or inherited fetch policy
- last fetch status and timestamps
- HTTP cache validators such as ETag and Last-Modified
- upstream category/source metadata hints
- optional Newspaper policy overrides
- timestamps

### `raw_items`

Immutable or revision-addressable upstream feed observations.

- Input Feed ID
- Outlet ID snapshot
- raw feed GUID
- discovered and normalized URLs
- title, author, publication timestamp, and updated timestamp
- raw feed body and summary
- source URL and source-name snapshots
- categories, tags, media, and enclosure metadata
- complete parsed metadata snapshot
- discovered timestamp

### `articles`

Outlet-specific canonical publications.

- stable application identifier
- required Outlet ID
- canonical and resolved URLs
- title, author, and publication timestamp
- primary dedupe key
- current extraction and classification outcome metadata
- first and last discovery timestamps
- timestamps

Articles from different Outlets remain separate even when syndicated or
substantially similar.

### `article_dedupe_keys`

All stable aliases that resolve to one Article inside one Outlet boundary.

- Article ID
- Outlet ID
- normalized URL or feed-provided stable-ID key
- key type
- unique constraint over Outlet and key

Preserving every observed key allows an Article first matched by URL to be
found later by a stable ID, and vice versa, without changing its stable
identity.

### `article_appearances`

Every discovery of an Article through an Input Feed and Raw Item.

- Article ID
- Input Feed ID
- Raw Item ID
- first-seen timestamp
- source-provided tags, categories, and other hints

This replaces the misleading `article_sources` name. The Outlet is the source;
this row is an appearance.

### `article_extractions`

Versioned or revision-addressable extraction artifacts reusable across all
consumers.

- Article ID
- source URL and final resolved URL
- implementation key
- extracted title, byline, and publication timestamp
- sanitized HTML and normalized text
- excerpt and site name
- quality and boilerplate-removal evidence
- deterministic input fingerprint
- implementation version
- created timestamp

The application may retain one current pointer while preserving the exact
artifact references used by generated feed items and Edition manifests.

### `article_classifications`

App-owned classification artifacts derived from extraction and metadata.

- Article ID and extraction revision
- taxonomy version
- primary-section candidate
- Topic/tag assignments
- political-content tag
- geographic and locality relationships
- entities and other clustering hints
- confidence and rationale
- implementation, model, prompt, and schema versions
- deterministic input fingerprint
- correction/review state where needed
- created timestamp

Feed categories and sub-feed membership are evidence for this artifact, not
authoritative labels.

## Reading Feed Tables

The current `generated_feeds` vocabulary may remain in storage while the UI
and planning use **Output Feed** consistently.

### `generated_feeds`

- stable Output Feed identifier
- title and description
- item limit, default `500`
- enabled state
- additive membership and later filtering policy references
- original or hosted link selection
- original or digest title selection
- original feed, extracted content, or digest body selection
- hosted-page digest visibility
- timestamps

### `generated_feed_outlets`

Additive membership selecting every enabled Input Feed currently owned by an
Outlet.

- generated feed ID
- Outlet ID
- created timestamp

### `generated_feed_input_feeds`

Additive membership selecting one Input Feed.

- generated feed ID
- Input Feed ID
- created timestamp

An Article selected through several memberships still produces one generated
feed item for that Output Feed.

### `generated_feed_items`

Durable Output Feed publication records.

- generated feed ID and Article ID
- stable generated feed item identifier used as RSS GUID
- publication and eligibility timestamps
- exact extraction and digest artifact references used
- selection/filter decision metadata
- rendered GUID, title, link, byline, timestamps, body, source, categories,
  media, and enclosure snapshots
- render source metadata and implementation version
- render and publication status/error
- first eligible and last rendered timestamps

Rendering changes do not change RSS GUIDs.

### `article_digests`

Versioned single-Article Reading Feed digest artifacts.

- Article and extraction IDs
- pipeline step attempt ID
- implementation key, initially `digestion.ollama.article_digest`
- model, prompt, and schema versions
- deterministic input fingerprint
- generated title and summary
- input/output metadata
- created timestamp

Explicit re-digestion creates a new artifact. Model chain of thought is never
requested or stored.

### `article_filter_decisions`

Output-specific policy decisions over shared Article classifications.

- Article ID
- Output Feed or policy scope
- implementation key and policy revision
- include, exclude, or review decision
- labels, confidence, and rationale
- exact Article Classification reference
- created timestamp

## Upstream Processing Tables

### `article_processing_policies`

Defines which shared upstream artifacts an Article should receive without
requiring Output Feed membership.

- Outlet or Input Feed scope
- extraction enabled/inherited state
- classification enabled/inherited state
- implementation/config references
- timestamps

Output Feed consumers and Newspaper participation may create demand for an
artifact, but they must converge on one reusable Article-level result rather
than scheduling competing output-specific extractions.

### `site_extraction_policies`

Per-host extraction escalation memory.

- site host
- minimum implementation and last successful implementation
- last failure kind
- escalation enabled state
- request pacing and adaptive backoff
- timeout
- strict minimum usable text length after cleanup
- notes and timestamps

Initial extractor implementations:

- `extraction.simple_html`
- `extraction.headless_browser`
- `extraction.headed_browser`

### `pipeline_steps`

Configured code-registered processing definitions.

- scope type and scope ID
- step type and implementation key
- position and enabled state
- validated config
- timestamps

The expansion should add Outlet, Input Feed, and shared-Article scopes where
they express upstream enrichment. Output Feed scope remains appropriate for
output-specific filtering, digestion, and rendering.

### `pipeline_step_attempts`

Durable queued and completed work history.

- pipeline definition reference when it still exists
- Article and generated feed item references where applicable
- parent batch run
- status and attempt number
- input and output snapshots
- exact artifact references
- normalized error/debug data
- retry timing
- started and finished timestamps

### `generated_feed_item_steps`

The exact output-specific processing definition and result selected for one
generated feed item.

- generated feed item ID
- current pipeline definition when it still exists
- step type, implementation key, order, and config snapshot
- definition fingerprint
- state and latest attempt
- exact artifact reference
- reused-artifact flag
- error and timestamps

Moving extraction upstream must preserve existing item-step and attempt
history. Compatibility rows may continue pointing to a shared extraction
artifact even after new extraction demand is scheduled upstream.

## Newspaper Policy and Taxonomy Tables

### `newspaper_configs`

Supports one initial Newspaper while allowing later multiple configurations.

- stable identifier and display name
- enabled state
- timezone
- content cutoff and delivery deadline
- normal admission threshold, initially `2.0`
- Local singleton threshold
- delivery destination/configuration reference
- stable hosted path identity
- timestamps

### `newspaper_outlet_policies`

- Newspaper config and Outlet IDs
- enabled state
- base effective weight override when different from Outlet default
- Local-only participation flag
- default inclusion/exclusion and role metadata
- timestamps

### `newspaper_policy_overrides`

Absolute, non-compounding overrides.

- Newspaper config ID
- Outlet ID
- optional Input Feed ID
- override kind: Topic, section, Local, or locality
- taxonomy term or locality reference
- effective weight
- include/exclude state
- timestamps

The most specific applicable rule wins. The UI should be able to explain the
inheritance path.

### `taxonomy_terms`

Stable configurable Sections and Tags.

- stable internal identifier
- term kind: primary section or secondary tag
- label
- enabled/visible state
- display order
- alias or successor metadata for future taxonomy changes
- timestamps

### `localities`

- stable identifier and display name
- locality type such as municipality, county, metro, state, or custom
- parent locality where applicable
- canonical geographic identifiers and geometry/bounds when useful
- enabled state
- timestamps

## Event and Evidence Tables

### `events`

Cross-Outlet clusters representing one occurrence or development.

- stable identifier
- status and clustering implementation revision
- candidate headline or normalized descriptor
- earliest/latest occurrence, publication, and discovery times
- primary-section, Topic, entity, and locality candidates
- clustering evidence and confidence
- created/updated timestamps

### `event_articles`

- Event ID and Article ID
- relationship status and clustering evidence
- added-by implementation or operator
- created timestamp

### `article_dependencies`

Known syndication, citation, or common-origin relationships.

- dependent Article ID
- origin Article, document, or external-source reference
- relationship kind and confidence
- evidence metadata
- created timestamp

These relationships affect evidentiary independence without erasing the
dependent Article or its Outlet's contribution to coverage breadth.

### `event_cluster_actions`

Auditable merge, split, attach, and detach operations.

- action type
- source and target Event references
- affected Article IDs
- operator or implementation actor
- reason and evidence snapshot
- created timestamp

Actions should be explicit and reversible before publication. Published
Edition manifests remain unchanged.

### `story_threads`

- stable identifier
- display descriptor
- `active` or `dormant` state
- inactivity threshold/config used
- last qualifying Event timestamp
- created/updated timestamps

### `story_thread_events`

- Story Thread and Event IDs
- ordering or occurrence timestamp
- relationship evidence
- created timestamp

### `claims`

- Event ID
- normalized or rendered proposition
- Claim type
- uncertainty/status metadata
- extraction implementation and input revision
- created timestamp

### `claim_evidence`

- Claim ID
- Article, primary document, statement, or other evidence reference
- exact source location or excerpt locator
- relationship such as support, contradiction, qualification, or attribution
- origin-chain and independence metadata
- interested-party role
- confidence/rationale metadata
- created timestamp

The exact minimal vocabulary is finalized before these tables are implemented.
Do not store model chain of thought.

## Edition Tables

### `editions`

Immutable scheduled publication records.

- Newspaper config ID
- stable identifier and edition date
- timezone, cutoff, and delivery deadline
- status
- sealed manifest and manifest fingerprint
- taxonomy, policy, weight, model, prompt, schema, and implementation versions
- phase metrics and aggregate counts
- published timestamp
- stable hosted path
- created timestamp

The manifest identifies exact Article, extraction, classification, Event,
evidence, and configuration revisions.

### `edition_stories`

Immutable rendered stories within an Edition.

- Edition, Event, and optional Story Thread IDs
- stable identifier and ordering
- primary section and secondary-tag snapshots
- headline and compact-summary snapshots
- full prose snapshot
- Story So Far snapshot
- coverage-source snapshot
- citation/provenance snapshot or exact child references
- synthesis implementation metadata
- validation status

### `edition_story_citations`

- Edition Story and Claim IDs
- citation number
- exact Claim Evidence reference
- rendered source-label and link snapshots
- source-location snapshot

### `corrections`

- correction type: correction, clarification, or retraction
- affected Edition Story and optional Claim
- later Edition and Corrections-section story reference
- explanation and corrected understanding
- evidence references
- created timestamp

### `delivery_attempts`

- Edition ID
- channel, initially email
- destination snapshot
- status and provider response metadata
- attempted timestamp
- retry relationship

Delivery retry does not regenerate the Edition.

## Operations and Settings

### `runs`

Durable execution records for fetch, canonicalization, extraction,
classification, clustering, synthesis, edition generation, delivery, and bulk
pipeline work.

- run type and trigger
- parent run and related domain references
- pipeline attempt ID where applicable
- status, timestamps, and phase
- summary counts and metrics
- error summary and debug metadata

### `failures`

Visible retryable or terminal failures.

- failure type
- related Outlet, Input Feed, Article, Event, Edition, delivery, or run
- message and normalized failure kind
- retryable state, retry count, and next retry time
- last attempted timestamp
- related record and run references

### `app_settings`

Application-wide operational defaults, including:

- global feed fetch interval
- Ollama base URL and selected Article-digestion model
- later default classification and synthesis implementations

Edition-specific scheduling belongs in `newspaper_configs`.

### `retention_policies`

Deferred explicit retention rules.

- scope
- maximum age or item count
- protection rules for published or cited artifacts
- enabled state
- last run timestamp

Published Edition snapshots, Citation evidence, stable generated-feed identity,
and artifacts referenced by immutable manifests must not disappear through
ordinary autopurge.

## Required Migration Invariants

The `IntakeGroup` to `Outlet` and `ArticleSource` to `ArticleAppearance`
migration must preserve:

- every Input Feed and fetch setting
- stable Article, Output Feed, and generated feed item identifiers
- every Raw Item, dedupe key, and Article Appearance
- every generated RSS GUID and rendered snapshot
- extraction, digest, pipeline attempt, run, and failure history
- current Output Feed memberships

Each currently ungrouped Input Feed receives an Outlet during migration. The
migration should infer only obvious one-feed Outlets and require operator
confirmation where several feeds may represent one editorial identity.

Target relationship changes:

```text
intake_groups                    -> outlets
input_feeds.intake_group_id      -> input_feeds.outlet_id (required)
article_sources                  -> article_appearances
generated_feed_intake_groups     -> generated_feed_outlets
output-scoped extraction demand  -> upstream Article enrichment demand
```
