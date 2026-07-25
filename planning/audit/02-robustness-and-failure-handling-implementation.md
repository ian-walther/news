# Robustness And Failure Handling Implementation Notes

Temporary reconciliation note for `planning/audit/02-robustness-and-failure-handling.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- R-1: Extraction and digestion dispatchers monitor worker tasks and release queue capacity when a task exits without reporting completion.
- R-2: Attempts with unusable article URLs fail terminally with explicit operator-visible state.
- R-3: Dispatcher and execution crash paths close any open per-attempt run record.
- R-4: External commands run in their own process group; timeout terminates the whole group, and the production container now uses `tini`.
  - Tests cover argv commands and a worker that spawns a child process.
- R-5: Application startup closes interrupted non-pipeline operations and reconciles durable item-step bookkeeping.
- R-7: Scheduler fallback now emits an explicit warning, and the settings row is protected by a database singleton constraint with conflict-safe creation.
- R-8: Retry counters advance only after the failure has passed retryability and supported-type validation.

## Not Implemented

- R-6: No new job framework or generic operation dispatcher was introduced.
  - These commands remain application-supervised tasks, while their durable run records provide completion/error visibility and startup recovery closes interrupted operations.
  - Re-render already reports completion to a still-mounted LiveView. Processing remains the authoritative place to inspect work after navigation.

## Auditor Notes

- R-6 is an intentional scope boundary, not a claim that LiveView ownership is durable. The task supervisor owns execution; the LiveView only starts the command and may show immediate feedback.
- Focused dispatcher, recovery, and command-worker tests passed before full-suite reconciliation.
