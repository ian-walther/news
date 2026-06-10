# Configurable Processing Pipeline

## Goal

Introduce a first-class, UI-configurable processing pipeline before adding content extraction.

The pipeline should make extraction, summarization, filtering, rendering, and later newspaper preparation feel like variations of the same underlying model rather than one-off feature branches.

## Core Model

A pipeline is made of ordered steps.

Each step has:

- step type
- implementation
- enabled flag
- position
- implementation-specific config
- scope
- attempt history

Step type describes what kind of work is being done.

Examples:

- extraction
- summarization
- filtering
- rendering
- newspaper section selection

Implementation describes how that work is done.

Examples:

- `extraction.simple_http`
- `extraction.headless_browser`
- `extraction.host_chrome`
- `summarization.local_llm.brief`
- `summarization.local_llm.section_digest`
- `filtering.local_llm.topic_policy`
- `filtering.source_policy`
- `rendering.rss_item`

## Configuration

Pipeline configuration should be available in the admin UI from the beginning.

The first UI does not need to be fancy, but it should be real:

- list configured steps for an output feed
- add a step
- edit a step
- enable or disable a step
- delete a step
- set implementation-specific config fields

Step ordering should be represented in the data model from the start. Move up/down controls can wait if necessary, but the model should not assume a single hardcoded extraction step.

## Scope

The first configurable pipeline should attach to output feeds.

Output-feed scope fits the first compelling use case:

- a generated feed can opt into extraction
- the same article can be rendered differently for different output feeds later
- later summaries and filters can vary by feed

The model should leave room for future scopes:

- input feed
- intake group
- global default
- generated output feed

Scope precedence can wait until multiple scopes are needed. Do not overbuild inheritance before the output-feed pipeline is useful.

## Implementation Registry

Available implementations should be defined in code, not invented by arbitrary database rows.

The database should store the selected implementation key and config. Code should own:

- implementation key
- step type
- display label
- config schema
- validation rules
- runtime module

This allows UI configurability without turning the database into an arbitrary code execution surface.

Example registry metadata:

```elixir
%{
  key: "extraction.host_chrome",
  type: :extraction,
  label: "Host Chrome extraction",
  config_schema: [
    %{name: :timeout_seconds, type: :integer, default: 45},
    %{name: :chrome_profile, type: :string, default: "newspaper"}
  ]
}
```

## Attempts And Outputs

Every meaningful step execution should create an attempt record.

Attempt records are for audit/debug history:

- step ID
- article ID
- generated feed item ID when applicable
- status
- input snapshot
- output snapshot
- error
- started timestamp
- finished timestamp

Domain outputs should still live in domain tables.

Examples:

- extracted content belongs in article extraction state or extraction tables
- summaries belong in summary tables
- filter decisions belong in filter decision tables
- rendered RSS state belongs in generated feed item snapshots

The attempt table explains what happened. Domain tables hold the current durable result used by later pipeline stages.

## Execution Model

Pipeline execution should be explicit and durable.

Avoid live processing during RSS requests. FreshRSS should receive already-rendered generated feed item snapshots.

For extraction, the expected path is:

```text
generated feed item exists
  -> configured pipeline step selected
  -> extraction attempt created
  -> implementation runs
  -> extracted content stored or failure recorded
  -> generated feed item re-rendered when configured output uses extracted content
```

Later stages should follow the same shape:

```text
article durable state
  -> step attempt
  -> validated output
  -> domain result stored
  -> downstream snapshots updated explicitly
```

## Initial Work

Initial implementation work should include:

- pipeline step schema
- pipeline step attempt schema
- implementation registry
- output-feed pipeline UI
- extraction step type
- at least one extraction implementation placeholder
- explicit attempt/failure visibility

The first real extraction implementation can then use this pipeline model instead of creating a one-off extraction path.

## Non-Goals

- Do not build a general workflow engine.
- Do not add arbitrary user-authored code execution.
- Do not implement prompt management for all future LLM stages before extraction works.
- Do not add complex scope inheritance until multiple scopes are actively useful.
- Do not process generated feeds lazily during RSS requests.
