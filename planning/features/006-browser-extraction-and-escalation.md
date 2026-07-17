# Browser Extraction And Escalation

## Goal

Complete authenticated and browser-state-dependent extraction without changing the app-facing pipeline contract.

The application owns extractor selection, escalation, pacing, durable attempts, and site policy. Worker executables only fetch and normalize one article request.

## Extractor Chain

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

`extraction.headless_browser` renders a page in an isolated browser context. `extraction.headed_browser` should connect to the persistent Chrome session on the production host for authenticated or browser-state-dependent sources.

Every implementation must preserve the shared JSON request/response contract, normalized content fields, failure taxonomy, and stderr/stdout separation.

## Escalation Behavior

The configured extraction step enables processing for an output feed but does not select an extractor. Site extraction policy determines the cheapest implementation worth attempting for a particular host and owns escalation, request pacing, timeout, and extraction-quality thresholds.

Escalation-worthy failures include:

- `javascript_required`
- `auth_required`
- `paywall`
- `blocked`
- repeated `insufficient_content`

Network failures and timeouts should remain transient scheduling or availability failures. An ordinary rate limit or a response with an explicit `Retry-After` should use site backoff without escalation. Repeated rate limits without `Retry-After` from the simple client may indicate bot classification rather than request volume, so they may trigger a headless probe. A successful probe may teach headless as the site's minimum implementation. A headless rate limit must not automatically escalate into the persistent headed browser.

Active site backoff should remain operator-overridable. A manual retry should bypass the current timer once without erasing rate-limit history; failure resumes adaptive backoff, while success clears it naturally.

`not_found` is not an extractor-capability failure and should not move execution farther up the browser chain. The application may try a distinct, URL-shaped, same-site feed stable ID to recover a changed permalink. If no candidate succeeds, the failure remains terminal for automatic processing and manually retryable by the operator.

When a higher implementation succeeds after a lower implementation fails, the app may learn that higher implementation as the site's minimum. The operator must be able to inspect and override learned policy.

## Headed Browser Topology

- Chrome runs on the host OS under a dedicated user.
- Chrome remains attached to the persistent Xorg dummy-display session.
- The dedicated Chrome profile preserves paid-site authentication.
- `x11vnc` shares the same display for login refresh and debugging.
- CDP is exposed only through a narrowly secured host/container boundary.
- Auth expiration and browser unavailability are visible operator failures.

## Quality Work

Use representative real articles from configured sources to define quality behavior before adding elaborate heuristics.

The review corpus should include:

- clean static articles
- JavaScript-rendered articles
- logged-out and expired-auth pages
- paywall interstitials
- bot challenges
- image-heavy articles
- very short legitimate articles
- malformed or unusually structured pages

Quality decisions should remain deterministic and auditable. Local LLMs can classify or digest extracted text later, but they should not silently rewrite extraction output into an unverifiable canonical article.

## Remaining Acceptance Criteria

- The headed worker exposes the same app-facing contract as simple and headless extraction.
- Auth expiration and unavailable Chrome sessions are visible and manually retryable.
