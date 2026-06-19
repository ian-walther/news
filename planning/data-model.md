# Data Model

## Direction

Use Postgres from the start. Feed history, intake groups, source appearances, generated feed state, extraction content, run history, and later classification results are durable application state.

SQLite is not a supported backend. The app should be configured with a database URL so development, initial production, and later shared-network production can all use Postgres without changing application architecture.

This is a planning sketch, not a final schema.

The data model should support eager durable intake. Source feeds are discovery inputs; generated output feeds render from app-owned records.

## Core Tables

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

- intake group ID for dedupe ownership
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
- configurable processing pipeline reference or scoped pipeline steps

### generated_feed_intake_groups

Additive membership rules that include all enabled input feeds in an intake group.

- generated feed ID
- intake group ID
- created timestamp

Including an intake group applies to enabled input feeds currently in the group and enabled input feeds added later.

### generated_feed_input_feeds

Additive membership rules that include individual input feeds.

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

## Processing Pipeline Tables

### pipeline_steps

Configured processing steps.

- scope type, initially output feed
- scope ID
- step type
- implementation key
- position
- enabled flag
- config
- created/updated timestamps

Step implementations are registered in code. Database rows select and configure those implementations.

### pipeline_step_attempts

Execution history for pipeline steps.

- pipeline step ID
- article ID when applicable
- generated feed item ID when applicable
- status
- input snapshot
- output snapshot
- error type/message/debug data
- started timestamp
- finished timestamp

Attempts are audit/debug records. Durable current outputs should be stored in domain tables.

### article_extractions

Durable extraction results.

- article ID
- implementation key
- status
- final URL
- extracted title
- extracted byline
- extracted publication timestamp
- extracted content
- quality/debug metadata
- created/updated timestamps

The first implementation can store extraction state directly on articles if that keeps the change small, but the model should be ready to move extraction output into a first-class table if multiple extraction attempts or revisions become important.

### site_extraction_policies

Per-site extraction escalation memory.

- site host
- optional input feed ID override
- minimum implementation key
- last successful implementation key
- last failure kind
- escalation enabled flag
- notes
- created/updated timestamps

The Elixir app owns this policy. Extractor executables should report normalized results and failure kinds, but they should not persist or decide long-term site policy.

Initial implementation keys:

- `extraction.simple_html`
- `extraction.headless_browser`
- `extraction.headed_browser`

New sites should start with `extraction.simple_html` unless an operator policy says otherwise. If lower-cost extractors fail in escalation-worthy ways and a higher extractor succeeds, the app can record the higher extractor as the site's minimum implementation.

### article_summaries

Future summarization outputs.

- article ID
- implementation key
- model/prompt/config metadata
- summary text or structured summary
- confidence/quality metadata
- created timestamp

### article_filter_decisions

Future filtering outputs.

- article ID
- output feed or policy scope
- implementation key
- decision
- labels
- confidence
- rationale
- model/prompt/config metadata
- created timestamp

### retention_policies

Future explicit retention/autopurge policies.

- scope
- max age or max item count
- enabled flag
- last run timestamp

## Later Tables Or Extensions

### classifications

- article ID
- model identity
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
- LLM prompt/schema revision references when semantic filtering exists
- enabled flag
- created/updated timestamps

### summaries

- article ID
- model identity
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
