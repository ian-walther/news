# Personalized Newspaper Planning

## Status

This directory is the active, forward-looking product and architecture contract
for the personalized Newspaper expansion.

The complete Trilium planning hierarchy was imported without reconciliation at
[`docs/source-material/trilium-newspaper/`](../../docs/source-material/trilium-newspaper/README.md).
That snapshot preserves the original wording, hierarchy, metadata, and
justifications. Do not edit the imported source material when refining the
active plan.

## Product Shape

The application has two complementary reading products over one shared article
corpus:

- **Reading Feed:** continuously updating, article-centric generated RSS for
  scanning and opening individual pieces.
- **Newspaper:** scheduled, event-centric hosted editions synthesized from
  coverage across configured sources.

The Reading Feed preserves worthwhile singleton articles. The Newspaper
identifies important events through weighted coverage, synthesizes factual
prose with claim-level citations, and publishes immutable daily artifacts.

## Planning Map

- [`product-contract.md`](product-contract.md) defines the user experience,
  edition contract, delivery model, sections, and initial scope.
- [`domain-model.md`](domain-model.md) defines Outlet, Input Feed, Article
  Appearance, Event, Story Thread, Edition, and the migration away from Intake
  Group terminology.
- [`source-and-admission-model.md`](source-and-admission-model.md) defines
  source configuration, weighting, Local policy, story admission, prominence,
  and explainability.
- [`editorial-model.md`](editorial-model.md) defines synthesis, evidence,
  citations, uncertainty, story continuity, and corrections.
- [`../implementation-roadmap.md`](../implementation-roadmap.md) sequences the
  expansion into implementable phases.
- [`../open-questions.md`](../open-questions.md) contains only unresolved
  decisions that remain relevant to future work.

## Source-of-Truth Rule

These reconciled documents govern implementation. The Trilium snapshot is the
lossless decision record used to audit interpretation or recover omitted
reasoning.

When the product direction changes:

1. Update the relevant active planning document to current truth.
2. Remove superseded requirements instead of recording progress history.
3. Preserve architectural rationale when it explains a constraint or guards
   against a likely regression.
4. Do not rewrite the imported Trilium snapshot.

