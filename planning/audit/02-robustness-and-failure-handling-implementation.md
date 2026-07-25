# Robustness And Failure Handling Implementation Notes

Temporary reconciliation note for
`planning/audit/02-robustness-and-failure-handling.md`.
Delete this file after the audit doc removes the completed item below.

## Implemented

- R-9: live publishing now keeps each output feed beside its item-creation
  result. Failed enrollments create a
  `generated_feed_item_create_failed` failure with feed, article, raw-item,
  input-feed, and run context, and they contribute to the processing run's
  failure count and status.

## Verification

- A regression test persists a deliberately invalid pipeline definition,
  reproduces the previously swallowed item-enrollment error, and verifies the
  failed run plus its related failure record.
