# Feed Source Management

## Goal

Allow the operator to define and manage upstream RSS and Atom input feeds and assign them to intake groups.

## Non-Goals

- Do not implement generated feed publishing here.
- Do not implement LLM filtering here.
- Do not require browser extraction for source setup.

## User / Operator Flow

The operator can create intake groups, add input feed URLs, assign each input feed to an intake group, enable or disable feeds, and see the latest fetch status.

V1 should keep source setup simple:

- intake group: name, optional notes
- input feed: name, URL/link, assigned intake group, enabled flag

In the UI, an intake group can be presented as a name with multiple feed links under it. In the data model, the links should remain individual input feed records that belong to the intake group.

## Data Model Impact

Primary table:

- `sources`
- `intake_groups`

Likely fields:

- URL
- name
- outlet
- intake group
- optional default category/source metadata
- enabled flag
- auth required flag
- fetch cadence
- last fetch status
- last fetched timestamp

## Implementation Notes

Use LiveView for source and intake group management. Keep the forms simple enough for V1: intake group name, feed URL, feed title/name, enabled flag, and optional notes.

Source configuration should be DB-backed from the start. Config files can still exist for environment settings, but they should not be the primary way to manage feed sources.

Provide a seed mechanism, but start with no real configured feeds by default. Real source examples should be added after the app exists and actual source behavior can be tested. Dev/test fixtures can exercise the pipeline without hardcoding real feeds into application logic.

Do not add slugs in V1 source/intake management. Use generated IDs for durable identity and names for human display.

## Failure Cases

- Invalid URL.
- Feed URL returns non-feed content.
- Feed requires auth.
- Feed is temporarily unreachable.

## Acceptance Criteria

- A source can be created, edited, disabled, and re-enabled.
- An intake group can be created and edited.
- An input feed can be created with a name and URL and assigned to an intake group.
- Source list shows latest status.
- Disabled sources are not fetched.
- Disabled intake groups make their child input feeds inactive for fetching.
- Disabling a source or intake group does not delete historical raw items, articles, appearances, or generated feed items.
- Source records are usable by the feed collection feature.
- Related sources can be grouped into an intake group for deduplication.

## Open Questions

- Should intake group names be free text initially or managed records with richer metadata?
- Should source auth requirements be manually marked or detected?
