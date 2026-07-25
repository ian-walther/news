# Correctness Bugs

Reconciled 2026-07-25 (second pass). **No open findings.**

C-1–C-10 are all implemented and verified. The final item, the C-6 residual
(explicit downstream step requests rewriting a succeeded prior step's
`finished_at`/`reused_artifact` through the `:bookkeeping` reuse path), was
fixed in `3070af5`: `Newspaper.Processing.maybe_mark_reused_success/3` leaves
`success_state/1` off the update when the row is already `succeeded` and
points at the same artifact, while still allowing definition
position/reference synchronization. The digestion pipeline regression test
forces a second digestion request and asserts the completed extraction step's
timestamp and reuse flag survive.
