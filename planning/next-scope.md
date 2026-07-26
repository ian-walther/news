# Active Planning Focus

## Goal

Close the current feed product as a dependable standalone baseline before
starting the personalized-newspaper expansion.

## In Scope

- Headed browser extraction through the persistent host Chrome session.
- Auth-expiration and unavailable-browser visibility for headed extraction.
- A real authenticated-source smoke test covering automatic escalation and
  learned site policy.
- Extraction or digestion refinements only when sustained use exposes a
  concrete failure or reading-quality problem.

The feed product is ready to close when its known aggregation, deduplication,
publishing, extraction, digestion, retry, and visibility workflows have no
open blockers and the authenticated headed-browser tier is available for
sources that require it.

## Designed-In But Later

- Personalized newspaper generation and delivery.
- LLM filtering step types.
- Review/correction workflows for model output.
- Reusable prompt/policy management.
- Provider-neutral LLM abstractions and model lifecycle management.
- Cross-source synthesis, clustering, and World Radar digestion.
- Global/intake/input-feed pipeline inheritance.
- Automatic digestion retries beyond explicit operator retry.
- Full rebuild/danger-zone operations.

## Non-Goals

- Do not replace the feed-only output path.
- Do not process articles live during RSS requests.
- Do not allow arbitrary database-defined code execution.
- Do not build a general workflow engine.
- Do not require every output feed to use extraction.
- Do not use raw RSS bodies as a silent fallback input for digestion.
- Do not turn article-digest tuning into a general LLM platform.
- Do not import or partially implement the larger expansion until its Trilium
  plans are deliberately reconciled into the repository.
