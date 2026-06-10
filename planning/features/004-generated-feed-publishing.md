# Generated Feed Publishing

## Goal

Publish generated RSS feeds from canonical article state so FreshRSS can subscribe to cleaned, deduplicated feeds.

Output feeds select from the post-intake article pool. They will commonly represent categories, but the mechanism should stay generic enough to support source bundles, review queues, and later policy-filtered feeds.

## Non-Goals

- Do not require full article extraction.
- Do not require LLM classification.
- Do not implement semantic filtering in V1.
- Do not alter FreshRSS or Reeder read/unread state.

## User / Operator Flow

The operator defines generated output feeds by selecting from intake groups, sources, categories, or later policy rules. Each generated feed publishes one output feed URL. FreshRSS subscribes to that URL, and Reeder receives the resulting feed items through the existing FreshRSS sync path.

V1 output feed URLs should use stable generated feed identifiers, not human-readable slugs. The URL can be ugly because FreshRSS is the consumer. Human-friendly names should appear in the admin UI and RSS feed title.

Do not add slugs in V1. Introduce slugs only if a compelling product or operational need appears later.

Each output feed should have a configurable item limit. The V1 default should be `500`, shown as a prepopulated editable field in the output feed form.

V1 generated feeds are selected by deterministic intake/source/category rules. Later, those rules can be extended with content-aware filtering policies after extraction and local LLM classification exist.

Generated feed publishing is based on durable generated feed item records. Output feeds should not be lazy views over the current contents of upstream source feeds.

V1 output feed membership should be additive-only and modeled with native relationships:

- included intake groups
- included individual input feeds

Including an intake group includes all enabled input feeds currently in that group and enabled input feeds added to that group later. Individual input feed inclusion exists for precise selection when only some feeds in an intake group should contribute to an output feed.

## Data Model Impact

Primary tables:

- `generated_feeds`
- `generated_feed_items`
- `generated_feed_intake_groups`
- `generated_feed_sources`
- `articles`
- `article_sources`

## Implementation Notes

Generated feeds should initially use original article URLs and pass through selected original upstream feed body content exactly.

Each durable object whose identity needs to remain stable should have a stable app-generated identifier. This includes canonical articles, generated output feeds, and generated feed items.

After extraction exists, article identifiers can be used for locally hosted article URLs. Feed identifiers can be used for stable generated feed URLs.

RSS item identity should be stable. Extraction, body upgrades, link target changes, or metadata corrections should not cause FreshRSS to treat the article as a new item.

Once extraction exists, output feeds should start with simple boolean settings:

- process/extract items
- link to hosted article instead of original article
- use extracted content body instead of original feed body

If process/extract is false, generated feeds should pass through selected original feed entry data without app-added body changes. If extracted content is unavailable, generated feeds should fall back to the original feed body unless a later policy says otherwise.

Selection should be modeled separately from rendering. An article can be eligible for a generated feed because of its intake/source/category rules, then later excluded or routed elsewhere by a filtering policy.

Eligibility should create or update a durable generated feed item record. Rendering the RSS feed should use the rendered snapshots stored on generated feed item records.

Generated feed item output should not be live-rendered from current article state on every RSS request. Updates caused by extraction, output feed setting changes, or metadata corrections should happen through explicit re-render/reprocess steps so behavior stays deterministic and easy to debug.

Generated feed item snapshots should be comprehensive. Store the rendered RSS-ish item metadata, not only the minimum fields needed for a feed response. The goal is to know what the app published without consulting the original upstream feed entry.

Output feed membership and rendering changes should be future-only by default. Existing generated feed items should not be changed or backfilled unless the user explicitly runs a rebuild/backfill/re-render action.

Backfill and re-render should be separate actions. Backfill creates missing generated feed items from existing articles. Re-render updates snapshots for existing generated feed items without fetching upstream RSS, mutating raw intake data, or changing generated feed item GUIDs.

Potential body modes:

- original feed body
- extracted full text
- summary
- excerpt plus links

V1 only needs exact original feed body pass-through.

Future filtering policies should support use cases such as excluding political-topic articles from otherwise valuable sources whose political coverage is considered unreliable or propagandistic.

## Failure Cases

- Generated feed definition has no matching articles.
- RSS rendering fails.
- Feed contains invalid XML.
- FreshRSS rejects or mishandles output.
- Generated feed item state becomes inconsistent with article state.

## Acceptance Criteria

- At least one generated RSS endpoint exists.
- A generated feed can select articles from the post-intake article pool.
- A generated feed can include whole intake groups.
- A generated feed can include individual input feeds.
- Intake-group inclusion applies to current and future enabled input feeds in that group.
- V1 output feed membership is additive-only.
- FreshRSS can subscribe to the generated endpoint.
- Feed items are deduplicated.
- Feed item membership is durable and app-owned.
- Feed item render snapshots include title, link, GUID, author, timestamps, summary/body, source metadata, categories/tags, and media/enclosure metadata when available.
- Output feed rule changes apply to future items by default.
- Generated feed endpoints return the most recent item snapshots up to the output feed item limit.
- Disabled output feeds do not create new generated feed items and their endpoints return `404`.
- Unprocessed feed item bodies pass through the selected original upstream body exactly.
- Feed entries link to original source articles.
- Feed item GUIDs are stable across rendering changes.
- RSS item GUIDs use explicit generated feed item identifiers.
- Generated output feed URLs can use stable feed identifiers rather than mutable names.
- Generated feed output validates as RSS.
- Feed rendering failures are visible.

## Open Questions

- What is the minimum V1 rule model for defining generated output feed membership?
- How should later filtering policies attach to generated feeds?
- When should explicit excludes be added?
- What manual rebuild/backfill controls should exist in the admin UI?
- Should full rebuild be deferred as a later admin-danger-zone action?
- Are there source-specific metadata fields that should be preserved specially during raw capture?
