# Test Coverage Gaps

Reconciled 2026-07-25. T-1 through T-9 were implemented and verified — the
suite grew from 76 to 104 Elixir tests plus 16→20 worker JS tests, covering
direct FeedController output, parser fixtures (RSS2 + Atom), concurrent intake
convergence, dispatcher task-death and invalid-URL handling, membership
preservation semantics, eligibility/pagination beyond the old cap, item-step
history preservation, crash/startup run cleanup, and fingerprint determinism.

## T-10 (residual) — Pin the `minimum_text_length` threshold behavior

Blocked on the **D-6** decision (see `03-plan-divergences.md`): the worker
currently accepts content down to ~70% of the configured minimum
(`scoreQuality` score ≥ 0.35). Whichever way D-6 is decided, add a worker test
that pins it:

- If the soft threshold is intended: a test with content at ~80% of
  `minimum_text_length` asserting `status: "ok"` with the
  `content_text_shorter_than_*` reason, and one well below 70% asserting
  `no_content`.
- If a strict floor is chosen: tests asserting `no_content` at 99% of the
  minimum and `ok` at 100%.

The other T-10 items (Retry-After HTTP dates, redirect final-URL propagation,
unsupported content types, delimiter handling under sanitize-html, argv
commands, timeout child-process cleanup) landed and were removed.

## New-coverage note from reconciliation

When **C-6 residual** and **R-9** (see 01/02) are fixed, they need their own
red-first tests — named there. When **P-1 residual** lands, add the
reload-coalescing LiveView test described in 05.
