# Canonicalization And Deduplication

## Goal

Map raw feed items to canonical article records within intake groups and avoid publishing duplicate repeated items downstream.

## Non-Goals

- Do not implement semantic clustering here.
- Do not use LLMs for V1 dedupe.
- Do not dedupe across unrelated intake groups in V1 unless explicitly reviewed.
- Do not discard source appearance history.

## User / Operator Flow

The operator can see that several raw feed items within an intake group resolved to one canonical article and inspect which input feeds contained it.

## Data Model Impact

Primary tables:

- `raw_items`
- `intake_groups`
- `articles`
- `article_sources`
- `failures`

## Implementation Notes

V1 should use two conservative dedupe signals:

- normalized URL
- feed-provided stable ID

Design the dedupe engine to be extensible, but do not enable fuzzy or semantic dedupe until real feed behavior proves it is needed.

Start with deterministic URL normalization:

- Normalize scheme and host where appropriate.
- Strip known tracking parameters.
- Normalize trailing slashes where safe.
- Preserve the original discovered URL.

Feed-provided stable IDs can be used to prevent duplicate entries from the same feed or publisher when they are reliable. They should not be blindly trusted across unrelated feeds unless later evidence shows that a publisher uses globally stable IDs.

Later improvements may use resolved redirects, canonical link metadata from extracted HTML, and title/date/source similarity. These are not V1 dedupe signals.

V1 dedupe should primarily handle repeated articles published to multiple feeds within the same intake group. Cross-outlet story clustering belongs to later semantic enrichment, morning newspaper planning, or World Radar work.

When duplicate raw items collapse to one canonical article in unprocessed/pass-through mode, V1 only needs to pick one representative upstream entry for the generated feed item snapshot. It does not need to merge bodies or preserve all duplicate bodies in the rendered output.

Use the earliest timestamp as the representative selection rule. If entries are effectively tied or identical, any deterministic arbitrary tie-break is acceptable. The exact winner is not product-critical because the long-term product path expects article extraction to become the meaningful content source; the important V1 output requirement is preserving a usable article URL and stable article identity.

Representative timestamp hierarchy:

1. earliest usable feed item `published_at`
2. fallback earliest usable feed item `updated_at`
3. fallback earliest `discovered_at`
4. fallback deterministic raw item ID/order

## Failure Cases

- URL cannot be parsed.
- Different URLs within an intake group appear to represent the same article but confidence is low.
- Same URL appears with conflicting titles or timestamps.
- Feed-provided stable IDs conflict with URL evidence.

## Acceptance Criteria

- Raw items are associated with canonical article records.
- Duplicate raw items across input feeds in an intake group map to the same article.
- V1 dedupe uses normalized URL and feed-provided stable ID only.
- Representative raw item selection uses earliest timestamp with deterministic arbitrary tie-break.
- Source appearances are preserved.
- Generated feed publishing can select one item per canonical article.

## Open Questions

- Which URL parameters should be stripped globally?
- Should outlet-specific canonicalization rules exist in V1?
- What feed-provided ID patterns are reliable enough to use across feeds from the same publisher?
- Should V1 ever dedupe across intake groups?
- How should ambiguous matches be surfaced?
