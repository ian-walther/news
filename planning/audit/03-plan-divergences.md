# Plan Divergences

Reconciled 2026-07-25 (second pass). **No open findings.**

D-1–D-11 are all resolved — implemented, or resolved by deliberate planning-doc
amendment where the docs were behind a sound implementation decision.

## D-6 decision record

D-6 had one full round-trip worth remembering: the first implementation pass
refuted the finding ("`minimum_text_length` is a strict minimum") and the
Auditor verified that refutation as incorrect — the worker accepted content
down to ~70% of the configured minimum via the quality-score path. The second
pass then **chose and implemented the strict floor**: `extractArticleFromHtml`
returns `no_content` whenever cleaned content length is below
`minimum_text_length`, worker tests pin both sides of the boundary (499 →
`no_content`, 500 → `ok` at the default), and `planning/pipeline.md` plus the
worker READMEs document the floor with the intended escape hatch — sites that
publish legitimate short material get a lower site-specific minimum in their
site extraction policy.

Operational note for real-source usage: short-but-legitimate articles on
sites still at the default 500-character minimum will now surface as
escalate-then-skip (`no_content`) instead of extracting. That is the chosen
behavior; the remedy is tuning that site's policy minimum, not re-softening
the floor.

## Explicitly Fine / Leave-Alone

- **Digest summary reflow** (`normalize_summary`/`reflow_summary` reshaping
  model output into 3–5 paragraphs): documented behavior, auditable via the
  verbatim model output stored in `output_metadata["raw_content"]`. The
  paragraph-count validation after reflow is effectively cosmetic — known and
  accepted.
- **Per-feed fetch pacing/cadence:** global cadence with conditional requests
  is the accepted state; `workflow.md` defers per-feed schedules.
- **Digestion failure classification by message string-matching**
  (`Newspaper.Digestion.digestion_error/1`): the matched strings are produced
  by the app's own `OllamaClient`; fine until that client's error surface
  changes.
