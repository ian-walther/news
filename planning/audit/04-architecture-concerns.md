# Architecture Concerns

Reconciled 2026-07-25. A-1 (fetch-scoped processing), A-2 (single content
authority + data-preserving legacy migration), A-3 (relative hosted paths,
absolutized at the feed boundary), A-4 (materialized item-step bookkeeping +
startup reconciliation), and A-9 (Saxy XML) were implemented, verified, and
removed. One slim residual and standing verdicts remain.

---

## A-6 (residual) — Output-feed eligibility still exists as two queries

- **Severity:** low (was medium; the semantic drift risk was fixed)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/publishing.ex` — `list_eligible_articles/2` (backfill) vs `eligible_generated_feed_ids/1` (live publishing)

Both paths are now query-based, live in `Publishing`, and encode the same
rule (direct input-feed inclusion, or enabled-input-feed-within-included-group,
per the amended `pipeline.md`). That resolved the original bug surface (D-8)
and the N+1. What remains is structural: the rule is written twice in two
query shapes (article→feeds vs feeds→article), so a future rule change —
explicit excludes are already planned — must be made in both places or they
drift silently.

**Decision:** when the next membership-rule change arrives (likely the
planned exclude work), extract one shared composable query fragment (e.g., a
`Publishing.eligible_pairing_query/0` joining articles×feeds on the
membership predicate) and derive both call sites from it. Not worth churn
before then; this entry exists so the next rule change triggers it.

**Effort:** M (with characterization tests: the existing backfill/publish
eligibility tests serve as guardrails).

---

## DECISION-NEEDED

- **A-8 — auth posture and direct port exposure:** now recorded as two
  explicit questions in `planning/open-questions.md` (trusted-LAN-only
  posture? keep Phoenix port LAN-reachable beside nginx?). Owner: Ian. No
  audit action until answered.

---

## Explicitly Fine / Leave-Alone

- **A-5 (three hand-built dispatchers):** accepted. The shared failure class
  (task death wedging queues) was fixed with monitors in both dispatchers;
  the remaining duplication is structural taste, and their responsibilities
  genuinely differ (host-paced queue / single resource queue / durable batch
  registry). **Revisit trigger:** when the headed-browser tier adds a third
  execution queue or another job type appears — that is the plan's own
  "job surface grows" threshold for reconsidering a shared abstraction or
  Oban.
- **A-7 (Pipeline/Processing/Publishing boundary):** accepted at current
  feature surface; cross-domain calls are traceable. Reconsider only
  alongside a real feature that forces the item-creation flow to change.
- **A-2 note:** `articles.extraction_status` + `extraction_metadata` remain
  as a deliberately documented denormalized latest-outcome cache for UI
  queries; `article_extractions` is the single content authority. Don't
  re-flag the cache as duplication.
