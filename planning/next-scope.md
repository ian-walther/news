# Active Planning Focus

## Goal

The current product focus is a configurable processing pipeline that supports content extraction as the first real processing step.

The feed-only path is the foundation. The app becomes compelling when generated feeds can use extracted article content and local hosted article pages.

## In Scope

- Pipeline step model.
- Pipeline step attempt/audit model.
- Code-owned implementation registry.
- Output-feed pipeline configuration UI.
- Extraction step type.
- Three extraction implementation slots with a shared contract: simple HTML, headless browser, and headed browser.
- App integration for the simple HTML extraction executable.
- App-owned extraction escalation and site-level minimum extractor policy.
- Durable extraction output state.
- Extraction failure visibility.
- Hosted article pages using stable article identifiers.
- Explicit re-rendering of generated feed item snapshots after extraction changes usable output state.

## Designed-In But Later

- LLM filtering step types.
- LLM summarization step types.
- Review/correction workflows for model output.
- Reusable prompt/policy management.
- Global/intake/input-feed pipeline inheritance.
- Automatic retry/backoff.
- Full rebuild/danger-zone operations.

## Non-Goals

- Do not replace the feed-only output path.
- Do not process articles live during RSS requests.
- Do not allow arbitrary database-defined code execution.
- Do not build a full workflow engine before extraction works.
- Do not require every output feed to use extraction.
- Do not make summarization or filtering part of the initial extraction work.
