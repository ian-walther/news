# Architecture Concerns

Reconciled 2026-07-25 (second pass). A-1–A-4, A-8, and A-9 are resolved. One
trigger-based residual and standing verdicts remain.

---

## A-6 (residual) — Output-feed eligibility still exists as two queries

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/publishing.ex` — `list_eligible_articles/2` (backfill) vs `eligible_generated_feed_ids/1` (live publishing)

Both paths are query-based, live in `Publishing`, and encode the same rule
(direct input-feed inclusion, or enabled-input-feed-within-included-group).
What remains is structural: the rule is written twice in two query shapes
(article→feeds vs feeds→article), so a future rule change — explicit excludes
are already planned — must be made in both places or they drift silently.

**Decision:** when the next membership-rule change arrives (likely the
planned exclude work), extract one shared composable query fragment and
derive both call sites from it. Not worth churn before then; this entry
exists so the next rule change triggers it.

**Effort:** M (guardrails: the existing backfill/publish eligibility tests).

---

## Explicitly Fine / Leave-Alone

- **A-8 (security posture):** resolved by explicit product decision, recorded
  durably in `README.md` (Security Boundary), `planning/architecture.md`, and
  `planning/prod-topology.md` (Network And Access Boundary): Newspaper is a
  trusted-LAN application; network reachability is the authorization
  boundary; VPN for remote access; direct Phoenix port access on the LAN is
  acceptable; nginx is a routing convenience, not a security boundary; public
  exposure is unsupported without a separate security design. Do not re-flag
  missing app auth while that boundary stands.
- **A-5 (three hand-built dispatchers):** accepted. The shared failure class
  (task death wedging queues) was fixed with monitors; the remaining
  duplication is structural taste, and their responsibilities genuinely
  differ. **Revisit trigger:** when the headed-browser tier adds a third
  execution queue or another job type appears — the plan's own "job surface
  grows" threshold for a shared abstraction or Oban.
- **A-7 (Pipeline/Processing/Publishing boundary):** accepted at current
  feature surface; cross-domain calls are traceable. Reconsider only
  alongside a feature that forces the item-creation flow to change.
- **A-2 note:** `articles.extraction_status` + `extraction_metadata` remain a
  deliberately documented denormalized latest-outcome cache for UI queries;
  `article_extractions` is the single content authority. Don't re-flag the
  cache as duplication.
