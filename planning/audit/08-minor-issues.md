# Minor Issues and Nitpicks

Reconciled 2026-07-25. N-1, N-3–N-6, N-8, N-9, N-11–N-15, and N-17 were
implemented and verified (Saxy RSS with `dc:creator`/self-link/optional
pubDate/enclosures, LIKE escaping, batched intake events, changeset field
separation, DB-enforced settings singleton, honest backoff listing, list-page
feed toggle that preserves memberships, single-truncation digestion with
model-visible fingerprints, argv worker commands, healthcheck + tini +
`--wait` deploys + required `DATABASE_URL`, domain-side rendering validation,
persisted retry origin/attempt numbers in Processing).

---

## N-2 (open, product decision) — URL-normalization strip list for dedupe

Unchanged: dedupe URL normalization strips only `utm_*`, `fbclid`, `gclid`;
publisher-specific parameters (`mod=`, `ref=`, `smid=`, `partner=`) still
defeat URL dedupe, and http/https / `www.` variants are distinct keys. The
implementer's caveat is correct and adopted as the decision frame: expand the
strip list **from observed duplicate pairs in real data**, not speculatively —
over-stripping can merge genuinely distinct resources. The stable-ID alias
dedupe (C-2 fix) reduces how often this matters. Tracked in
`planning/open-questions.md` (Deduplication). Owner: Ian, informed by real
duplicates surfacing in the article pool.

---

## Explicitly Fine / Leave-Alone

- **N-7:** second-granularity pacing drift — accepted at multi-second
  intervals.
- **N-10:** hosted read route existing only for extracted content (404
  otherwise) — intended behavior.
- **N-16:** legacy string-ID tolerance at the failure-related boundary —
  accepted (see 06).
- **`DATABASE_URL` as the explicit contract** rather than composing it from
  Postgres parts in Compose: implementer's argument accepted (it is the
  documented portability seam for the shared-Postgres future); production now
  fails fast when unset.
- **Digestion fingerprint change side effect:** fingerprints now hash only
  model-visible (truncated) content, so pre-existing digests of >60k-char
  articles won't match and will regenerate on the next explicit request
  instead of reusing. One-time, self-healing, correct going forward.
