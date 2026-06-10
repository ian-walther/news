# Admin And Review UI

## Goal

Provide enough operator visibility to configure sources, inspect pipeline state, and understand failures.

## Non-Goals

- Do not build a polished consumer reading interface.
- Do not replace FreshRSS or Reeder.
- Do not build complex classifier review before classification exists.

## User / Operator Flow

The operator can open the Phoenix LiveView UI and answer practical questions:

- Are sources fetching successfully?
- What new items were discovered?
- Which articles were deduplicated within intake groups?
- What generated feeds exist?
- What failed and needs attention?

## Data Model Impact

This feature mostly reads existing tables:

- `sources`
- `intake_groups`
- `raw_items`
- `articles`
- `article_sources`
- `generated_feeds`
- `runs`
- `failures`

## Implementation Notes

Keep the UI operational and dense. It should be a control surface, not a marketing page.

Initial V1 screens:

- Failures / Recent Activity.
- Intake Groups.
- Input Feeds.
- Output Feeds.
- Articles.
- Runs.

The landing page should be operational rather than decorative. Use Failures / Recent Activity as the dashboard placeholder. A richer dashboard can emerge later once real usage makes the useful summary content obvious.

Screen responsibilities:

- Failures / Recent Activity: recent fetch/render failures, recent runs, and actionable operational status.
- Intake Groups: create/edit groups, enable/disable groups, show child input feeds.
- Input Feeds: create/edit feeds, assign groups, enable/disable feeds, show last fetch status.
- Output Feeds: create/edit output feeds, set item limit, show GUID-based feed URL, manage included intake groups and individual input feeds.
- Articles: browse canonical articles, source appearances, representative raw item, and generated feed items.
- Runs: inspect fetch, intake processing, publishing, backfill, and re-render run history.
- Settings: configure global fetch interval.

## Failure Cases

- Long lists become hard to scan.
- Failure messages lack enough context.
- Operator cannot tell why an item did not appear downstream.

## Acceptance Criteria

- Source status is visible.
- Run history is visible.
- Run history includes verbose debugging information by default.
- Failures are visible.
- Retryable failures can be retried manually.
- Canonical article/source appearances are inspectable.
- Generated feed definitions and URLs are visible.
- Intake groups, input feeds, and output feeds are configurable through the UI.

## Open Questions

- What filters are needed first on the Articles and Runs screens?
- What failure lifecycle states are needed after real usage?
