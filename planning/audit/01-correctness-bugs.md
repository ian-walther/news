# Correctness Bugs

Reconciled 2026-07-25. C-1–C-5 and C-7–C-10 were implemented, verified against
the diff and tests, and removed. Only the C-6 residual remains.

---

## C-6 (residual) — Explicit step requests still rewrite completed prior-step history

- **Severity:** low (was medium; the main path is fixed)
- **Confidence:** certain (traced call path; not executed)
- **Location:** `newspaper/lib/newspaper/processing.ex` — `ensure_existing_item_step/5` reusable-artifact branch; reached via `request_item_step/3 → reconcile_prior_steps/2` (`:bookkeeping` mode) and via `:requested` mode on already-succeeded steps

The original C-6 (passive `advance_item` passes clobbering succeeded item-step
rows) is fixed: `advance_item_step` now treats `succeeded` as a plain
continue, and `digestion_pipeline_test.exs` ("preserves…" assertions at
lines ~190-197) pins it.

But one rewrite path survives. `ensure_existing_item_step` sends every
non-`:force` mode through `reusable_artifact/2`, and when an artifact exists
it unconditionally updates the row with `success_state(true)` —
`reused_artifact: true` and `finished_at: now`. Concretely:

1. Operator clicks **Digest** on an already-extracted article (or a digestion
   batch enrolls items): `request_item_step(item, "digestion", …)` calls
   `reconcile_prior_steps(item, digestion_step)`.
2. That calls `ensure_item_step(item, extraction_step, :bookkeeping)` on the
   **extraction** row, which is `succeeded` with `reused_artifact: false` and
   a real historical `finished_at`.
3. The reusable-artifact branch rewrites it: `reused_artifact` becomes `true`,
   `finished_at` becomes now.

So after any digestion batch over existing items, every extraction item-step
row reads as "satisfied by reuse just now", losing the fresh-work/reuse
distinction and original completion time — the same fidelity issue C-6
described, now confined to explicit-request paths.

**Decision:** in `ensure_existing_item_step`, when the existing row's status
is already `succeeded` and its artifact reference matches the reusable
artifact, return it untouched (update only `pipeline_step_id`/`position` if
the definition moved). Apply `success_state(true)` only when the row
transitions from a non-succeeded status, or when the artifact reference
actually changes. The `:requested`-mode no-artifact clause
(`:missing when status == "succeeded"`) already returns untouched — mirror
that for the artifact-present case.

**Guardrails/tests:** extend the existing history-preservation test in
`test/newspaper/digestion_pipeline_test.exs` (or a sibling) to call
`Processing.request_item_step(item, "digestion", force: true)` after a fresh
extraction and assert the extraction step's `finished_at`/`reused_artifact`
survive. Red-first per AGENTS.md.

**Effort:** S.
