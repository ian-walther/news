# Plan Divergences

Reconciled 2026-07-25. D-1–D-3, D-5, D-7–D-11 were implemented (or resolved by
updating the planning docs, which was the right call for D-1/D-7/D-9) and
removed. D-4's actionable part landed (raw model output preserved in
`article_digests.output_metadata["raw_content"]`). One finding stays open
because the implementation receipt refuted it incorrectly.

---

## D-6 — `minimum_text_length` is still not a strict minimum (refutation was incorrect)

- **Severity:** low
- **Confidence:** certain — re-verified against current `workers/extraction-core/src/article.mjs` after the implementation pass
- **Location:** `workers/extraction-core/src/article.mjs` — `scoreQuality/3` (`score: Math.max(0.1, contentLength / minimumTextLength / 2)`) vs the cutoff in `extractArticleFromHtml` (`if (quality.score < 0.35)`)

The implementation receipt claimed: "The audit description is factually
incorrect: the worker applies `minimum_text_length` as a strict minimum."
That is not what the code does, and no code or test in the implementation
commit touched this path. Arithmetic:

- `contentLength = 400`, `minimumTextLength = 500` → branch
  `contentLength < minimumTextLength` fires → score = `max(0.1, 400/500/2)`
  = **0.4** → `0.4 < 0.35` is false → the result is returned with
  `status: "ok"` (reason `content_text_shorter_than_500`).
- General form: any content ≥ 70% of the configured minimum passes as `ok`;
  only below 70% does the score drop under the 0.35 no-content cutoff.

So the operator-facing "Minimum text length" field and the data-model's
"minimum acceptable text length" describe a floor the worker does not enforce.
The original finding stands unchanged: **either** document/rename the ~70%
soft-threshold behavior as intended (it is defensible under the plan's
"legitimate short prose remains article content") **or** make the floor
literal and keep the fuzzy score for diagnostics only.

This needs a decision before T-10's threshold test can be written — the test
pins whichever behavior is chosen. Marking the behavior choice
**DECISION-NEEDED** (product call: is 70%-of-minimum acceptance the intent?);
the follow-through (docs+test, or code change+test) is implementer work.

**Effort:** S either way.

---

## Explicitly Fine / Leave-Alone

- **Digest summary reflow** (`normalize_summary`/`reflow_summary` reshaping
  model output into 3–5 paragraphs): documented behavior, now auditable since
  the verbatim model output is stored in `output_metadata["raw_content"]`.
  The paragraph-count validation after reflow is effectively cosmetic — known
  and accepted.
- **Per-feed fetch pacing/cadence:** global cadence with conditional requests
  is the accepted state; `workflow.md` already defers per-feed schedules.
- **Digestion failure classification by message string-matching**
  (`Newspaper.Digestion.digestion_error/1`): brittle in principle, but the
  matched strings are all produced by the app's own `OllamaClient`; fine until
  that client's error surface changes.
