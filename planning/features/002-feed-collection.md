# Feed Collection

## Goal

Fetch configured RSS and Atom input feeds and persist discovered raw feed items with their intake group context.

## Non-Goals

- Do not deduplicate canonical articles here beyond preserving raw item and intake group context.
- Do not publish generated feeds here.
- Do not extract full article content here.

## User / Operator Flow

The operator can trigger or schedule source fetches and inspect fetch results, including new item counts and failures.

V1 should support:

- manual fetch now
- app-wide scheduled fetch interval

Default scheduled fetch interval:

- `60` minutes

The global interval should be configurable in the admin UI. Per-feed schedules are deferred until real usage shows they are needed.

Use a supervised GenServer-style scheduler/runner for V1. Do not introduce Oban in V1.

## Data Model Impact

Primary tables:

- `sources`
- `intake_groups`
- `raw_items`
- `runs`
- `failures`

## Implementation Notes

Use `fiet` as the initial RSS/Atom parser rather than hand-parsing feeds. It is MIT licensed, pure Elixir, and explicitly targets RSS2/Atom parsing with standard compliance and extensibility.

Store comprehensive raw parsed metadata from upstream entries so the app does not need to depend on the original feed entry once the item has been ingested.

Feed collection should be a raw capture boundary. It should not try to normalize source-specific semantics during intake. Later pipeline stages can canonicalize URLs, resolve articles, dedupe, classify, or render snapshots.

The collector should be idempotent. Re-fetching a feed should not create duplicate raw items for the same source item.

Each raw item should retain both its input feed and intake group so downstream dedupe can operate within the intended boundary.

## Failure Cases

- Network timeout.
- Invalid feed XML.
- Unsupported feed format.
- Feed returns HTTP error.
- Source requires authentication.

## Acceptance Criteria

- Enabled sources can be fetched.
- New raw items are persisted.
- Re-fetching does not duplicate already-known raw items.
- Raw item records preserve available upstream metadata, including body, summary, author, timestamps, categories/tags, and media/enclosure data when present.
- Fetch run summaries are stored.
- Fetch run debug metadata is stored by default.
- Fetch failures are visible.
- A global scheduled fetch interval can fetch enabled input feeds.
- The global scheduled fetch interval defaults to 60 minutes and is configurable in the admin UI.

## Open Questions

- Are per-feed schedules needed after real usage?
