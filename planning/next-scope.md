# Active Planning Focus

## Goal

Prove extraction and digest quality through sustained use with real output feeds, then use observed failures and reading behavior to choose the next pipeline work.

## In Scope

- Real-source extraction quality review and failure classification.
- Headless browser extraction behind the shared extractor contract.
- Headed browser extraction through the persistent host Chrome session.
- App-owned escalation across extractor implementations.
- A small output-feed pilot using `qwen3.6:27b` digest titles and summaries in Reeder.
- Prompt, length, and validation tuning driven by actual reading quality.
- Revisit model selection only when the pilot exposes a concrete quality or throughput problem.
- Digestion failure review before any automatic retry policy is introduced.

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
- Do not use raw RSS bodies as a silent fallback input for digestion.
- Do not turn article-digest tuning into a general LLM platform.
