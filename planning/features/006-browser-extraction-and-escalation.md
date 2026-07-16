# Browser Extraction And Escalation

## Goal

Expand article extraction beyond direct HTML fetches without changing the app-facing pipeline contract.

The application owns extractor selection, escalation, pacing, durable attempts, and site policy. Worker executables only fetch and normalize one article request.

## Extractor Chain

```text
extraction.simple_html
  -> extraction.headless_browser
  -> extraction.headed_browser
```

`extraction.headless_browser` should render a page in an isolated browser context. `extraction.headed_browser` should connect to the persistent Chrome session on the production host for authenticated or browser-state-dependent sources.

Every implementation must preserve the shared JSON request/response contract, normalized content fields, failure taxonomy, and stderr/stdout separation.

## Escalation Behavior

The configured extraction step enables processing for an output feed. Site extraction policy determines the cheapest implementation worth attempting for a particular host.

Escalation-worthy failures include:

- `javascript_required`
- `auth_required`
- `paywall`
- `blocked`
- repeated `insufficient_content`

Network failures, timeouts, and rate limiting should remain transient scheduling or availability failures. They must not teach the app that a more capable extractor is required.

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

Quality decisions should remain deterministic and auditable. Local LLMs can classify or summarize extracted text later, but they should not silently rewrite extraction output into an unverifiable canonical article.

## Remaining Acceptance Criteria

- Headless and headed workers expose the same app-facing contract as simple HTML extraction.
- The Elixir app can escalate through available implementations during one pipeline attempt.
- A successful higher implementation can teach site-level minimum implementation policy.
- Rate limits and transient network failures do not alter extractor capability policy.
- The operator can inspect and override site policy.
- Auth expiration and unavailable Chrome sessions are visible and manually retryable.
