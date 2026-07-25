# Plan Divergences Implementation Notes

Temporary reconciliation note for `planning/audit/03-plan-divergences.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- D-1: Updated the durable planning model to describe optional intake groups and per-feed dedupe boundaries.
- D-2: Added ETag and Last-Modified conditional requests plus a clear user agent.
- D-3: Preserved and rendered authors, categories, and enclosures.
- D-5: Digestion errors now distinguish configuration, structured output, model/HTTP, connection, and unknown execution failures with class-appropriate retryability.
- D-8: Group membership eligibility excludes disabled member input feeds in both live publishing and backfill.
- D-9: Documented the current `manual`, `scheduled`, `system`, `pipeline`, and `settings_change` trigger meanings.
- D-10: A corrupt or legacy policy referencing an unavailable extractor now fails terminally as `extractor_unavailable`.
- D-11: Updated the project instruction to use the established DaisyUI/Tailwind stack consistently.

## Not Implemented

- D-2 per-feed fetch pacing: intentionally deferred; collection still uses the global cadence, while conditional requests reduce unnecessary transfer and parsing.
- D-4: No change. The fixed digest contract remains a bounded product pilot rather than a general prompt platform.
- D-6: No change. The audit description is factually incorrect: the worker applies `minimum_text_length` as a strict minimum, matching the UI and data model.
- D-7: Rich `javascript_required`, `auth_required`, and `paywall` detection remains headed-browser quality work. The plans now distinguish those future semantic outcomes from failure kinds the current workers can actually observe.

## Auditor Notes

- An unavailable headed extractor cannot be selected through normal policy validation. The new terminal failure protects legacy or directly persisted invalid rows.
- The global database URL remains authoritative in production; Compose does not derive it from the bundled Postgres fields because shared-network Postgres is a planned configuration-only move.
