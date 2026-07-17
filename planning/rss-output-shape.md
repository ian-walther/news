# RSS Output Shape

## Direction

Generated output feeds should be configurable, but the defaults should be conservative and FreshRSS/Reeder-friendly.

Feed items should link to the original article and pass through the selected original upstream feed title and body unless an output feed explicitly chooses another available durable artifact. Pipeline steps schedule extraction and digestion; title, link, and body settings only control rendering.

Output feeds should render from durable generated feed item records created by the pipeline. They should not be lazy mirrors of whatever is currently present in upstream source feeds.

## Article Identity

Each durable object whose identity needs to remain stable should have a stable app-generated identifier.

At minimum, generate stable identifiers for:

- canonical articles
- generated output feeds
- generated feed items

Article identifiers should be usable for:

- stable internal article identity
- generated RSS item identity
- local hosted article URLs

Output feed identifiers should be usable for:

- stable output feed URLs
- RSS feed-level identity metadata
- deriving per-feed item identities if needed

Example hosted article URL shape:

```text
/articles/:article_guid
```

Example generated feed URL shape:

```text
/feeds/:feed_guid.xml
```

Generated output feed URLs should use the stable feed GUID as the canonical URL. They do not need to be pretty because FreshRSS is the main consumer. Human-friendly names belong in the admin UI and RSS feed title metadata, not in the stable URL identity.

Identifier formats must not depend on mutable title text, output feed membership, slug text, source URLs, or rendered body content.

Avoid slugs app-wide until there is a compelling reason to introduce them. Stable generated identifiers should carry durable identity and URL behavior.

## RSS GUID

Generated RSS item GUIDs should be stable.

The GUID should not change when:

- extraction later succeeds
- the item body changes from original feed body to extracted content
- a generated digest title or summary is selected
- an existing digest is regenerated
- the output feed switches from original article links to hosted article links
- article metadata is corrected

Stable GUIDs reduce the risk that FreshRSS treats an updated item as a new unread item.

RSS item GUIDs should use the explicit generated feed item GUID.

Generated feed items are first-class durable publication records, not just computed relationships between output feeds and articles. This is intentional: Postgres should comfortably handle the extra metadata, and explicit item identity gives the system more flexibility for publication history, migrations, reprocessing, and future feed behavior.

## Link Target

Original link behavior:

- Feed item links point to the original article URL.

Output ordering should use the published timestamp snapshot copied from the representative raw item. If no usable published timestamp exists, fall back to discovered time.

## Feed Window

Each output feed should have a configurable item limit.

Default item limit:

- `500`

The item limit should be shown as a prepopulated field when configuring an output feed, so the user is nudged to choose the desired value instead of inheriting hidden behavior.

RSS output should return the most recent generated feed item snapshots for that output feed, ordered by rendered/published timestamp descending with discovered time as a fallback.

Extracted link behavior:

- Each output feed should have a boolean setting controlling whether item links point to the original article or the hosted extracted article page.

Suggested setting:

- `link_to_hosted_article`

When false, RSS item links point to the original article. When true and extracted hosting is available, RSS item links point to the local hosted article URL.

## Title Source

Each output feed should select its rendered item title source explicitly:

- `original`
- `digest`

The default is `original`. `digest` uses the generated title from the current successful article-digest artifact for that output's configured digestion step.

The title source is independent of body and link selection. A feed may use a digest title while retaining full extracted content and original article links.

## Body Source

Original body behavior:

- Feed item bodies pass through the selected original upstream feed body/content exactly.
- No source attribution, dedupe explanation, summaries, or other app-added content should be injected when the original body is selected.

Extracted body behavior:

- `extracted_content` uses the sanitized HTML from the current successful article extraction.
- When extraction is unavailable, the item is not extraction-ready; the selected publication policy decides whether it waits or temporarily renders original content.

An enabled extraction pipeline step is the only output-level switch that requests extraction. It automatically schedules future generated feed items. Existing items require an explicit bulk extraction action, preserving future-only configuration semantics.

Digest body behavior:

- `digest_summary` uses the generated summary from the current successful article-digest artifact.
- Model output remains plain text; the application escapes it and renders predictable feed-safe paragraphs.

The body-source setting is one explicit selector:

- `original_feed`
- `extracted_content`
- `digest_summary`

The default is `original_feed`. Moving to one selector avoids overlapping booleans and unclear precedence as digest output becomes available.

If a selected digest artifact is not ready, the item is not digest-ready. Whether publication waits for the digest or temporarily publishes original content is an open product decision that must be explicit and visible rather than an accidental fallback.

## Configurability

Keep rendering settings simple while processing pipeline steps are introduced.

Output-feed rendering settings:

- `link_to_hosted_article`
- `title_source`
- `body_source`

## Render Snapshots

Generated feed items should store rendered RSS snapshots.

Do not live-render generated feed item bodies directly from current article state on every RSS request. The system is brittle by nature, so output should be deterministic and easy to reason through.

Generated feed item snapshots should include the rendered values needed for RSS output, such as:

- GUID
- title
- link URL
- author/byline
- publication timestamp
- updated timestamp
- summary/excerpt
- body/content
- source name
- source URL
- categories/tags
- media/enclosure metadata when present
- rendered timestamp
- render source metadata

The goal is to store enough rendered metadata that the generated feed item can be understood and republished without needing to consult the original upstream feed entry.

When article state changes, extraction succeeds, or output feed settings change, the system should use an explicit re-render/reprocess step to update generated feed item snapshots. GUIDs remain stable across re-rendering.
