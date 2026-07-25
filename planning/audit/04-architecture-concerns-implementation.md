# Architecture Concerns Implementation Notes

Temporary reconciliation note for `planning/audit/04-architecture-concerns.md`.
Delete this file after the audit doc has been updated to remove or revise the completed items below.

## Implemented

- A-1: A fetch canonicalizes only items returned by the current upstream response; explicit intake reprocessing remains available separately.
- A-2: Removed the duplicate `articles.extracted_content` payload after a data-preserving artifact backfill.
  - `article_extractions` owns content, `articles.extraction_status` and metadata are denormalized current outcome state, and item steps remain output-specific workflow state.
- A-3: Hosted article decisions are snapshotted as relative paths and absolutized only at the HTTP feed boundary.
- A-4: Pipeline-step creation/update materializes bookkeeping rows for existing items, startup reconciles older gaps, and counts are one grouped status query with only a defensive missing-row fallback.
- A-6: Output eligibility is centralized in query-based `Publishing.list_eligible_articles/2` and shared membership predicates.
- A-9: RSS rendering uses Saxy rather than string concatenation.

## Not Implemented

- A-5: The dispatchers were not collapsed into one generic abstraction or replaced with Oban.
  - Extraction is host-keyed and paced, digestion is a single resource queue, and batch enrollment has a different durable responsibility. Their shared task-death failure class is fixed with monitoring.
- A-7: Module ownership was not reorganized solely for architectural symmetry. Current cross-domain calls remain traceable at the present feature surface.
- A-8: Authentication and direct-port exposure require a product/security posture decision and remain open in `planning/open-questions.md`.

## Auditor Notes

- A-2 intentionally preserves a compact article-level status cache for high-frequency UI queries; full extracted content no longer has multiple authorities.
- A-3 chooses the relative-path option suggested by the audit and keeps snapshots portable across host/scheme changes.
