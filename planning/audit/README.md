# Codebase Audit — Reconciled 2026-07-25

Independent audit performed 2026-07-24 against commit `b83bcb7`; the
implementation pass landed in `329770f` and was reconciled by the Auditor on
2026-07-25 (full diff review of semantics-bearing changes, full test suites
re-run: 104 Elixir + 20 worker JS tests green, credo clean).

These docs are **forward-facing**: completed findings are deleted, not marked
done. Gaps in ID sequences mean implemented-and-removed. What remains below is
only open work, residuals, refutations, and deliberate leave-alone verdicts.

## Files

| File | Open contents |
| --- | --- |
| [01-correctness-bugs.md](01-correctness-bugs.md) | C-6 residual |
| [02-robustness-and-failure-handling.md](02-robustness-and-failure-handling.md) | R-9 (new, low); R-6 leave-alone verdict |
| [03-plan-divergences.md](03-plan-divergences.md) | D-6 open (implementer refutation was incorrect); leave-alone notes |
| [04-architecture-concerns.md](04-architecture-concerns.md) | A-6 residual; A-8 decision pointer; leave-alone verdicts |
| [05-performance-and-scalability.md](05-performance-and-scalability.md) | P-1 residual; P-3 informational; leave-alone verdicts |
| [06-dead-code-and-schema-cruft.md](06-dead-code-and-schema-cruft.md) | No open findings; one audit-claim refutation recorded |
| [07-test-coverage-gaps.md](07-test-coverage-gaps.md) | T-10 residual (blocked on D-6) |
| [08-minor-issues.md](08-minor-issues.md) | N-2 open (product decision); leave-alone verdicts |
| [09-strengths.md](09-strengths.md) | Verified behaviors that must not be "fixed" (unchanged) |

## Reconciliation summary

Implemented and verified (removed from docs): C-1–C-5, C-7–C-10, R-1–R-5,
R-7, R-8, D-1–D-3, D-5, D-7–D-11, A-1–A-4, A-9, P-2, P-5, X-1–X-4, X-6–X-8,
T-1–T-9, N-1, N-3–N-6, N-8, N-9, N-11–N-15, N-17. X-5 was implemented except
one sub-item where the audit's no-caller claim was stale (refutation recorded
in 06). The implementation was faithful and in several places better than the
audit's suggested fix (dedupe alias table with advisory locks and historical
GUID backfill; data-preserving legacy-content migration; process-group worker
termination; the "intake boundary" planning-doc treatment of ungrouped feeds).

Still open, in priority order:

1. **D-6** — `minimum_text_length` is not the strict floor the receipt claimed
   (refutation verified incorrect with arithmetic; see 03).
2. **C-6 residual** — explicit digestion requests still rewrite the succeeded
   extraction item-step's history via the `:bookkeeping` reuse path (see 01).
3. **P-1 residual** — per-attempt `:processing_changed` broadcasts still drive
   full requeries of the Processing/OutputFeed pages during batches (see 05).
4. **A-6 residual** — output-feed eligibility exists as two queries that can
   drift (see 04).
5. **R-9** — item-creation errors in the live publish loop are silently
   swallowed (new, low; see 02).
6. **A-8 / N-2** — product decisions parked in `planning/open-questions.md`
   (auth posture / direct port exposure; URL-parameter stripping).
