# Correctness Bugs Implementation Notes

Temporary reconciliation note for `planning/audit/01-correctness-bugs.md`.
Delete this file after the audit doc removes the completed item below.

## Implemented

- C-6 residual: explicit downstream step requests now preserve the original
  completion timestamp and reuse flag when a succeeded prior step still points
  at the same artifact. Pipeline definition position and references can still
  be synchronized without rewriting execution history.

## Verification

- The digestion pipeline regression test now forces a second digestion request
  and verifies that the completed extraction step remains unchanged.
