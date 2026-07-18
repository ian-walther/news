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
- title source selector: original or digest
- body source selector: original feed, extracted content, or digest summary
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

Durable execution records for fetch, publish, extraction, classification, and bulk pipeline work. A bulk pipeline run is the parent operator-visible batch for its individual step attempts.

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
- Ollama base URL, initially `http://desktop.home:11434`
- globally selected Ollama article-digestion model

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

An output-feed extraction row selects the site-policy coordinator. It does not store a concrete extractor choice or extractor-specific configuration.

The enabled state of that row is the sole output-level extraction scheduling switch. Enabled steps schedule future generated feed items; existing items are only scheduled through an explicit bulk action. Output rendering selectors consume available artifacts but do not request processing.

### generated_feed_item_steps

The durable step definition and state snapshotted for one generated feed item.

- generated feed item ID
- current pipeline step ID when the definition still exists
- step type, implementation key, and position
- config snapshot and definition fingerprint
- status and latest attempt ID
- exact extraction or digest artifact reference
- reused-artifact flag
- error and execution timestamps

These rows distinguish the output feed's current definition from the work requested and completed for an existing item. Deleting a current pipeline definition must not erase item state or execution history.

### pipeline_step_attempts

Execution history for pipeline steps.

- pipeline step ID when the definition still exists
- generated feed item step ID when applicable
- article ID when applicable
- generated feed item ID when applicable
- parent batch run ID when the attempt belongs to a bulk operation
- status
- input snapshot
- output snapshot
- error type/message/debug data
- started timestamp
- finished timestamp

Attempts are audit/debug records. Bulk operations should associate attempts with a durable parent run so progress and completion remain reconstructable. Durable current outputs should be stored in domain tables.

### article_extractions

Durable current extraction artifact for an article. Extracted content is article-level reusable state even when an output-feed pipeline step caused the work.

- article ID
- implementation key
- final URL
- extracted title
- extracted byline
- extracted publication timestamp
- sanitized extracted HTML
- normalized extracted text
- excerpt and site name
- quality/debug metadata
- created/updated timestamps

Attempt snapshots preserve execution history. Future revision history can become first-class if correction or comparison workflows need more than the current artifact plus attempts.

### site_extraction_policies

Per-site extraction escalation memory.

- site host
- minimum implementation key
- last successful implementation key
- last failure kind
- escalation enabled flag
- minimum request interval and adaptive backoff state
- extraction timeout
- minimum acceptable text length
- notes
- created/updated timestamps

The Elixir app owns this policy. Extractor executables should report normalized results and failure kinds, but they should not persist or decide long-term site policy.

Initial implementation keys:

- `extraction.simple_html`
- `extraction.headless_browser`
- `extraction.headed_browser`

New sites should start with `extraction.simple_html` unless an operator policy says otherwise. If lower-cost extractors fail in escalation-worthy ways and a higher extractor succeeds, the app can record the higher extractor as the site's minimum implementation.

### article_digests

Versioned article-digest artifacts produced from successful extraction content.

- article ID
- extraction ID
- pipeline step attempt ID
- implementation key, initially `digestion.ollama.article_digest`
- Ollama model name
- prompt/schema version
- deterministic input fingerprint
- generated title
- generated summary
- input/output metadata
- generated timestamp

Explicit re-digestion creates another artifact rather than mutating prior output. Generated feed item step rows reference the exact artifact selected for that item, while pipeline attempts retain execution history. The model's chain-of-thought should not be requested or stored.

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
