# Performance And Scalability Implementation Notes

Temporary reconciliation note for `planning/audit/05-performance-and-scalability.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- P-1: Feed ingestion suppresses per-row broadcasts, emits operation-level changes, and LiveViews respond only to domain events relevant to their data.
- P-2: Backfill uses SQL eligibility and keyset batches without the 5,000-article correctness cap.
- P-5: Eligible output feeds are loaded in one query, new-item rendering avoids the unconditional second render, OutputFeed no longer double-fetches its feed, and Ollama discovery runs asynchronously.

## Not Implemented

- P-3: Retention remains an explicit product-policy decision and is already tracked in `planning/open-questions.md`.
- P-4: Fresh Chromium per headless extraction remains intentional for isolation and operational simplicity. Revisit a persistent browser worker only when measured throughput justifies the additional lifecycle complexity.
- P-5 residual micro-optimizations: no abstraction or bulk rewrite was added where existing preloads already prevent repeated loads or the current scale does not justify extra complexity.

## Auditor Notes

- Processing still refreshes promptly from durable events; this pass reduces event fan-out rather than adding JavaScript debounce behavior.
- Backfill remains intentionally row-oriented for item creation side effects, but eligibility and pagination no longer have the previous query/correctness cliff.
