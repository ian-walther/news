# Data Model

## Direction

Use Postgres from the start. Feed history, intake groups, source appearances, generated feed state, extraction content, run history, and later classification results are durable application state.

SQLite is not a supported backend. The app should be configured with a database URL so development, initial production, and later shared-network production can all use Postgres without changing application architecture.

This is a planning sketch, not a final schema.

The data model should support eager durable intake. Source feeds are discovery inputs; generated output feeds render from app-owned records.

## Core V1 Tables

### sources

Configured upstream input feeds.

- feed URL
- display name
- outlet/source name
- intake group ID
- optional default category/source metadata
- enabled flag
- auth requirement flag
- fetch cadence
- last fetch status

### intake_groups

Aggregation and deduplication units for related input feeds.

- name
- optional outlet/logical source name
- enabled flag
- dedupe strategy/configuration
- notes

### raw_items

Items discovered from source feeds.

- source ID
- intake group ID
- raw feed GUID
- discovered URL
- title
- author
- publication timestamp
- updated timestamp
- raw feed body
- raw summary/excerpt
- source URL
- source name
- categories/tags
- media/enclosure metadata
- raw metadata
- raw parsed metadata snapshot
- discovered timestamp

### articles

Canonical article identity.

- intake group ID for V1 dedupe ownership
- stable app-generated article identifier
- canonical URL
- resolved URL
- title
- author
- outlet
- publication timestamp
- dedupe key
- extraction status
- extracted content fields for later use

### article_sources

Mapping between canonical articles and every feed/source where they appeared.

- article ID
- source ID
- raw item ID
- first seen timestamp
- source-provided tags/categories

### generated_feeds

Definitions for output feeds published to FreshRSS.

- stable app-generated feed identifier
- title
- description
- item limit, default `500`
- enabled flag
- inclusion rules over intake groups, sources, categories, or later policies
- optional future filtering/routing policy reference
- boolean controlling whether links point to hosted article pages
- boolean controlling whether items are processed/extracted
- boolean controlling whether bodies use extracted content when available

### generated_feed_intake_groups

Additive V1 membership rules that include all enabled input feeds in an intake group.

- generated feed ID
- intake group ID
- created timestamp

Including an intake group applies to enabled input feeds currently in the group and enabled input feeds added later.

### generated_feed_sources

Additive V1 membership rules that include individual input feeds.

- generated feed ID
- source ID
- created timestamp

### generated_feed_items

Durable article entries selected from the article pool for each generated output feed.

- generated feed ID
- article ID
- stable app-generated feed item identifier
- RSS GUID using the feed item identifier
- published timestamp
- item title
- item URL
- body mode
- selection/filter decision fields for future policy use
- rendered GUID
- rendered title snapshot
- rendered link URL snapshot
- rendered author/byline snapshot
- rendered publication timestamp snapshot
- rendered updated timestamp snapshot
- rendered summary/excerpt snapshot
- rendered body snapshot or reference
- rendered source name snapshot
- rendered source URL snapshot
- rendered categories/tags snapshot
- rendered media/enclosure snapshot
- rendered timestamp
- render source metadata
- render status/error
- publication status
- first eligible timestamp
- last rendered timestamp

### runs

Fetch, publish, and later extraction/classification runs.

- run type
- trigger, such as manual/scheduled/system
- status
- started timestamp
- finished timestamp
- summary counts
- related record references
- error summary
- debug metadata

### app_settings

Application-level settings.

- global fetch interval minutes, default `60`
- run history/debug logging enabled, default true

### failures

Visible failure queue.

- failure type
- related source, raw item, article, feed, or run
- message
- retryable flag
- retry count
- last attempted timestamp
- related record/run references

### retention_policies

Future explicit retention/autopurge policies.

- scope
- max age or max item count
- enabled flag
- last run timestamp

## Later Tables Or Extensions

### classifications

- article ID
- model/version
- labels
- confidence
- filter decision
- policy that produced the decision
- rationale
- created timestamp

### feed_policies

Future configurable policies for generated feed selection, filtering, and routing.

- generated feed ID or reusable policy scope
- policy name
- source/intake/topic/filter rules
- LLM prompt/schema/version references when semantic filtering exists
- enabled flag
- created/updated timestamps

### summaries

- article ID
- model/version
- summary type
- summary text
- created timestamp

### paper_runs

- run date
- status
- selected article IDs
- generated PDF path or blob reference
- delivery status

### ha_state_snapshots

- run ID
- MQTT/Home Assistant control values
- captured timestamp
