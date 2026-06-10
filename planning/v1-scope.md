# V1 Scope

## Goal

V1 proves the core reading loop:

```text
configured source feeds
  -> intake groups
  -> aggregation and deduplication within intake groups
  -> article pool
  -> generated output feeds
  -> FreshRSS
  -> Reeder
```

## In Scope

- Phoenix application with LiveView.
- Durable DB-backed configuration and state.
- Source feed configuration.
- Intake group configuration.
- Empty seed mechanism for setup/dev fixtures, with no hardcoded real feeds.
- RSS and Atom feed fetching.
- Initial feed parsing through `fiet`.
- Manual fetch and global scheduled fetch.
- Supervised GenServer-style scheduler/runner.
- Persisted verbose run history for debugging.
- Local development Compose file for Postgres only.
- Production Dockerfile for the app.
- Production Compose file for app plus initial app-specific Postgres.
- Raw feed item storage.
- Comprehensive raw parsed feed item metadata storage.
- Canonical article identity.
- Deduplication across input feeds within an intake group.
- Generated feed definitions.
- Per-output-feed item limit, default `500`.
- Additive generated output feed membership by intake group and individual input feed.
- Durable generated feed item records.
- Rendered RSS snapshots on generated feed item records.
- Generated RSS endpoint publishing.
- Admin/review UI for sources, runs, items, generated feeds, and failures.
- Data model fields that allow later extraction without a major redesign.
- Data model provisions for later filtering/routing decisions.

## Out Of Scope

- Full article extraction.
- Paid-site browser auth automation.
- LLM classification.
- LLM summarization.
- Morning newspaper PDF generation.
- Email delivery.
- Printing.
- World Radar.

## Designed-In But Not Required

The V1 data model should leave room for optional content extraction.

Generated feed items initially publish selected original feed metadata and feed body content without app-added body changes. Later, when extraction succeeds and processing is enabled, the generated feed item can use extracted article content instead.

V1 acceptance should not require extraction to work.

V1 feed items should link to the original article URL and pass through the selected original upstream feed body exactly. The item identity/GUID should be stable so later extraction and rendering changes do not create duplicate unread items in FreshRSS.

Generated output feeds should also have stable app-generated identifiers. Anything that needs stable identity should use generated IDs rather than mutable titles, slugs, source URLs, or rendered content.

V1 should use eager durable intake. Input feeds are discovery sources; output feeds render from app-owned raw item, article, source appearance, and generated feed item records.

Generated feed item output should be snapshot-based, not live-rendered from current article state on every RSS request. Re-rendering should be explicit.

Configuration changes should be future-only by default. Manual rebuild/backfill/re-render actions can be added for existing records, but they should require explicit user action.

The V1 output feed model should also leave room for later filtering and routing policies. V1 selection can be deterministic source/intake/category based, but later versions should be able to filter articles based on extracted content and local LLM decisions.

V1 output feed membership is additive-only. An output feed can include whole intake groups and individual input feeds. Including an intake group means all enabled input feeds currently in the group and enabled input feeds added to that group later.

V1 dedupe should use normalized URL and feed-provided stable ID only. Other signals can be added later if real source behavior requires them.

When duplicates collapse, V1 should choose the representative raw item by earliest timestamp, with deterministic arbitrary tie-breaks if needed.

Representative timestamp hierarchy is published timestamp, updated timestamp, discovered timestamp, then deterministic raw item order.

## Acceptance Criteria

- A user can configure multiple source feeds.
- A user can group related input feeds into intake groups.
- V1 source setup supports simple group names and feed name/URL links.
- The system can fetch source feeds and store raw items.
- The system can fetch manually and on a global configurable schedule.
- Raw items preserve enough metadata that the app does not need to consult the original upstream feed entry after ingestion.
- The system can identify duplicate articles from repeated source appearances within an intake group.
- V1 dedupe uses normalized URL and feed-provided stable ID.
- Duplicate representative selection uses earliest timestamp.
- The system preserves source-feed appearances for each canonical article.
- The system creates durable generated feed item records for eligible output feeds.
- The system stores rendered RSS snapshots for generated feed items.
- Generated feed item snapshots store comprehensive rendered metadata, not only title/link/body.
- Unprocessed generated feed item bodies pass through the selected original upstream body exactly.
- Output feed membership changes apply to future items by default.
- Output feeds can include whole intake groups.
- Output feeds can include individual input feeds.
- Intake-group inclusion applies to current and future enabled input feeds.
- Disabled input feeds/intake groups stop future fetching without deleting history.
- Disabled output feeds stop future generation and return `404` without deleting history.
- The system can publish at least one generated RSS feed.
- Generated feeds return a configurable rolling window of recent items, defaulting to 500.
- A generated RSS feed can select from the post-intake article pool.
- FreshRSS can subscribe to the generated feed.
- Generated feed entries link back to original articles.
- Generated feed item GUIDs are stable.
- RSS item GUIDs use explicit generated feed item identifiers.
- Generated output feeds have stable identifiers.
- Failures during feed fetch or feed generation are visible.
- Retryable failures can be retried manually.
- Run history is persisted for meaningful operations.
- The system does not mark anything read in FreshRSS or Reeder.
- V1 admin UI includes Failures / Recent Activity, Intake Groups, Input Feeds, Output Feeds, Articles, and Runs screens.

## Non-Goals

- Do not optimize for public multi-user hosting.
- Do not build AI routing before generated feeds work.
- Do not make Docker mandatory for normal local development.
- Do not make extracted content mandatory for V1 feed usefulness.
- Do not inject app-added attribution, summaries, or explanations into unprocessed feed item bodies.
- Do not make config-file-driven setup the primary operator experience.
- Do not make generated output feeds lazy mirrors of current upstream feed contents.
- Do not live-render generated feed item bodies from current article state on every request.
- Do not automatically backfill or rewrite existing generated feed items when configuration changes.
- Do not implement explicit output feed excludes in V1.
- Do not implement manual failure resolved/ignored/dismissed states in V1.
- Do not implement automatic retry/backoff in V1.
- Do not implement per-feed schedules in V1.
- Do not introduce Oban in V1.
- Do not introduce slugs unless a compelling need appears later.

## Database Assumption

Postgres is the only supported database backend. Dev and prod should both configure database access through a database URL.

Local development may use Dockerized Postgres. Initial production may use an app-specific Docker Compose Postgres service. Later production may point at a shared network Postgres instance.
