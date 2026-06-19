# Content Extraction

## Goal

Optionally extract full article content and use it to replace or enrich generated feed item bodies.

This is designed into the architecture from the start. It is not required for the feed-only foundation to work, but it is the first compelling product milestone and should happen before expecting the app to become part of daily reading.

## Non-Goals

- Do not block generated feed publishing on extraction.
- Do not make extracted content publicly available.
- Do not use extraction workers as durable state owners.

## User / Operator Flow

The operator configures extraction as a pipeline step in the admin UI.

The first scope should be output feeds. When extraction succeeds, generated feed entries can include extracted article content or link to hosted article pages according to output-feed rendering settings. When extraction fails, the generated feed can continue using original feed content and the failure becomes visible.

The application should own extraction orchestration and escalation policy. Worker executables should expose extraction capabilities, but they should not decide long-term product behavior, mutate durable state, or learn per-site policy on their own.

The first extraction pipeline should support an escalation chain:

```text
simple HTML fetch
  -> headless browser
  -> headed browser using the persistent host Chrome session
```

The app should store how far up the chain a site needs to start. A new site can begin at simple HTML extraction. If lower-cost extraction fails in a way that indicates JavaScript, auth, paywall, blocking, or insufficient content, the app can escalate and, when a higher implementation succeeds, remember the minimum useful extractor for that site.

## Data Model Impact

Likely fields or tables:

- article extraction status
- extracted text/content
- extraction metadata
- extraction failure records
- site extraction policy
- minimum extractor implementation per site
- last successful extractor implementation per site
- hosted article URL based on stable article identifier
- generated output feed link/body booleans
- generated output feed process/extract boolean
- explicit re-render path for generated feed items after extraction succeeds

## Worker Contract

Content extraction is the first feature that should force a real decision about separate executable boundaries.

Worker-backed extraction implementations should share the same JSON input/output contract so the app can treat them as interchangeable escalation steps.

The intended executables are:

- `extraction.simple_html`: fetch HTML directly and extract readable article content.
- `extraction.headless_browser`: render with an isolated browser context and extract content.
- `extraction.headed_browser`: connect to the persistent headed host Chrome session for authenticated or browser-state-dependent extraction.

The exact executable names can change, but the interface should not depend on which implementation is being called.

Input should include:

- schema revision
- implementation key
- article URL
- source metadata
- browser/profile/CDP configuration reference
- extraction options

Output should include:

- schema revision
- implementation key
- final URL
- success/failure status
- extracted title
- extracted byline
- extracted publication timestamp
- extracted content
- quality score or quality reason
- failure kind when extraction fails
- retryable flag when extraction fails
- debug metadata

If the JSON contract is kept, stderr is for human-readable logs and stdout or an output file is for JSON only.

## Implementation Notes

Extraction should be represented as a pipeline step type with multiple implementations.

Initial implementations:

- `extraction.simple_html`
- `extraction.headless_browser`
- `extraction.headed_browser`

The app should run the cheapest configured extractor that is allowed by site policy. If that implementation fails with an escalation-worthy failure kind, the app can try the next implementation in the chain during the same extraction run. It should then persist both attempt history and any learned site policy.

Example failure kinds:

- `network_error`
- `http_error`
- `javascript_required`
- `auth_required`
- `paywall`
- `blocked`
- `rate_limited`
- `insufficient_content`
- `parser_error`
- `timeout`
- `unknown`

Failure kinds such as `javascript_required`, `auth_required`, `paywall`, `blocked`, and repeated `insufficient_content` are candidates for escalation. Failure kinds such as `network_error` and `timeout` should not automatically teach permanent site policy.

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

- Extraction can be configured from the admin UI as an output-feed pipeline step.
- Extraction can be attempted for an article through a pipeline step implementation.
- Simple HTML, headless browser, and headed browser extractors expose the same app-facing contract.
- The Elixir app can escalate through extractor implementations and persist the minimum useful extractor per site.
- Successful extraction stores article content.
- Generated feed body can use extracted content when available.
- Generated feed links can point to hosted article pages when configured.
- Failed extraction records a visible failure and a step attempt.
- Failure does not prevent the article from appearing in generated feeds with original feed content.

## Open Questions

- Which parser library should be used after browser fetch?
- How should low-quality extraction be detected?
- What exact threshold or repeated-failure rule should teach a site-level minimum extractor?
