# Active Planning Focus

## Goal

Prove extraction quality across the real source corpus and add a useful local-LLM article-digest step for successfully extracted articles.

## In Scope

- Real-source extraction quality review and failure classification.
- Headless browser extraction behind the shared extractor contract.
- Headed browser extraction through the persistent host Chrome session.
- App-owned escalation across extractor implementations.
- A configurable Ollama base URL and live installed-model discovery.
- An output-scoped `digestion.ollama.article_digest` step with a selected model.
- One validated durable artifact containing a factual replacement title and reading summary.
- Explicit RSS title and body source selection for digest rendering.
- Operator-visible digestion backlog, attempts, failures, retry, and explicit bulk processing.

## Designed-In But Later

- LLM filtering step types.
- Review/correction workflows for model output.
- Reusable prompt/policy management.
- Provider-neutral LLM abstractions and model lifecycle management.
- Cross-source synthesis, clustering, and World Radar digestion.
- Global/intake/input-feed pipeline inheritance.
- Automatic retries beyond explicit operator retry and per-host pacing.
- Full rebuild/danger-zone operations.

## Non-Goals

- Do not replace the feed-only output path.
- Do not process articles live during RSS requests.
- Do not allow arbitrary database-defined code execution.
- Do not build a general workflow engine.
- Do not require every output feed to use extraction.
- Do not wait for every source to support browser extraction before trying digestion on successfully extracted articles.
- Do not use raw RSS bodies as a silent fallback input for digestion.
- Do not turn the first digest implementation into a general LLM platform.
