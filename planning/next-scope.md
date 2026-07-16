# Active Planning Focus

## Goal

Prove extraction quality across the real source corpus, expand extraction coverage where direct HTML is insufficient, and introduce the first useful local-LLM processing step.

## In Scope

- Real-source extraction quality review and failure classification.
- Headless browser extraction behind the shared extractor contract.
- Headed browser extraction through the persistent host Chrome session.
- App-owned escalation across extractor implementations.
- Site extraction policy visibility and operator overrides.
- The first local-LLM summarization implementation using durable extracted text.

## Designed-In But Later

- LLM filtering step types.
- Review/correction workflows for model output.
- Reusable prompt/policy management.
- Global/intake/input-feed pipeline inheritance.
- Automatic retries beyond explicit operator retry and per-host pacing.
- Full rebuild/danger-zone operations.

## Non-Goals

- Do not replace the feed-only output path.
- Do not process articles live during RSS requests.
- Do not allow arbitrary database-defined code execution.
- Do not build a general workflow engine.
- Do not require every output feed to use extraction.
- Do not wait for every source to support browser extraction before trying summarization on successfully extracted articles.
