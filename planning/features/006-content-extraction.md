# Content Extraction

## Goal

Optionally extract full article content and use it to replace or enrich generated feed item bodies.

This is designed into the architecture from the start. It is not required for the feed-only foundation to work, but it is the first compelling product milestone and should happen before expecting the app to become part of daily reading.

## Non-Goals

- Do not block V1 generated feed publishing on extraction.
- Do not make extracted content publicly available.
- Do not use extraction workers as durable state owners.

## User / Operator Flow

The operator enables extraction for selected sources, intake groups, or generated output feeds. When extraction succeeds, generated feed entries can include extracted article content. When extraction fails, the generated feed can continue using original feed content and the failure becomes visible.

## Data Model Impact

Likely fields or tables:

- article extraction status
- extracted text/content
- extraction metadata
- extraction failure records
- hosted article URL based on stable article identifier
- generated output feed link/body booleans
- generated output feed process/extract boolean
- explicit re-render path for generated feed items after extraction succeeds

## Worker Contract

Content extraction is the first feature that should force a real decision about separate executable boundaries.

The current working assumption is that the extraction worker receives JSON input and returns JSON output, but this is provisional until the feature is designed in detail.

Input should include:

- schema version
- article URL
- source metadata
- browser/profile/CDP configuration reference
- extraction options

Output should include:

- schema version
- final URL
- success/failure status
- extracted title
- extracted byline
- extracted publication timestamp
- extracted content
- debug metadata

If the JSON contract is kept, stderr is for human-readable logs and stdout or an output file is for JSON only.

## Implementation Notes

Preferred browser strategy:

- Chrome runs on the host OS as a normal headed browser.
- Chrome is always running via systemd.
- Chrome is attached to the persistent Xorg desktop session.
- Xorg uses a dummy display configuration.
- Chrome uses a dedicated persistent profile under a dedicated Linux user.
- `x11vnc` shares the existing X display for manual login, auth refresh, and debugging from macOS.
- The app or worker connects to Chrome over secured local CDP.

## Failure Cases

- Auth expired.
- Paywall/session blocks extraction.
- Page structure changed.
- Browser unavailable.
- Extraction parser returns low-quality content.

## Acceptance Criteria

- Extraction can be attempted for an article.
- Successful extraction stores article content.
- Generated feed body can use extracted content when available.
- Generated feed links can point to hosted article pages when configured.
- Failed extraction records a visible failure.
- Failure does not prevent the article from appearing in generated feeds with original feed content.

## Open Questions

- Should extraction be configured per source, per intake group, per generated feed, or some combination?
- Which parser library should be used after browser fetch?
- How should low-quality extraction be detected?
