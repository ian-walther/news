# Processing Redesign Implementation Audit

Scope: the uncommitted Processing redesign reconciliation against `6f3a89f`.
There are no remaining reproduced code findings in this focused review.
Keep browser acceptance and migration rehearsal separate from that conclusion;
passing the code review is not a claim that either has been performed.

## Remaining Acceptance

- Exercise Queue, History, Attention, Articles, and output-pipeline controls in
  a real browser, including contextual navigation, live updates, expanded
  histories, menu dismissal, and desktop/mobile layouts.
- Rehearse the actual production migration and startup recovery against an
  isolated, representative pre-change database. Include active shared work,
  retry-pending failures, queued replacements, exhausted retries, interrupted
  enrollment, and completed batch history. Confirm the explicit fallback for
  unrecoverable legacy membership is visible and does not report false success.
- Keep the review/deployment hold until those acceptance checks and release
  reconciliation are handled. On deployment, verify the intended commit,
  container health, recent logs, routes, and processing-specific smoke checks.

## Regression Requirements

Preserve these boundaries when changing the implementation or promoting audit
probes into the maintained suite:

- Cancellation withdraws unstarted demand, including a failed attempt whose
  allowed automatic retry does not exist yet. It must not create detached
  foreground work after the batch has been cancelled.
- A shared surviving consumer can still retry under its own active batch.
- A worker claim that wins the race remains running and can deliver its result;
  a claim arriving while cancellation holds the attempt lock is rejected after
  withdrawal. Keep independent database connections and controlled barriers.
- Migration preserves active legacy retry demand both before and after the
  replacement attempt exists. Recovery still enforces the original retry budget;
  temporarily reopening a retryable failure must never replenish that budget.
- Finished batch history and unrelated later requests remain separate.
- Queue projections preserve foreground/bulk priority and FIFO within each class.
- Preserve the corrected effective-host fixture: set both `canonical_url` and
  `resolved_url` when assigning a test article to another website.

## Verification Basis

The current review has the following evidence, not a browser or production
rollout signoff:

- `scripts/test.sh`: 211 Elixir tests and 25 worker tests pass.
- The 15 existing audit probes pass with seed 42.
- All 16 audit probes pass with seed 0, including the additional
  exhaustion-through-migration control in file 04.
- Warnings-as-errors compilation, formatting checks, and configured strict
  Credo warning checks pass. Non-mutating checks replace the precommit wrapper
  during review to avoid formatting or dependency-unlocking the reviewed tree.

Run from `newspaper/`:

```sh
mix test ../planning/audit/probes/03_processing_reconciliation_test.exs ../planning/audit/probes/04_processing_boundaries_test.exs ../planning/audit/probes/05_claim_cancellation_test.exs --seed 42
```

The distinct-connection probe commits uniquely identified fixtures only to
the guarded local test database and cleans up those IDs. Other audit probes
use rollback-only sandbox fixtures. Audit probes live outside the normal
application test directory, so run them explicitly until promoted.
