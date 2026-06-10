# Implementation Roadmap

## Configurable Processing Pipeline

- Add a first-class pipeline step model.
- Add a pipeline step attempt/audit model.
- Add an implementation registry owned by application code.
- Add output-feed pipeline configuration UI.
- Support adding, editing, enabling, disabling, deleting, and ordering steps.
- Store implementation-specific config in a validated shape.
- Keep step execution explicit; do not run processing during RSS requests.

## Content Extraction

- Add the extraction step type.
- Add at least one real extraction implementation.
- Add host Chrome extraction for authenticated or JavaScript-heavy sites.
- Add simpler extraction implementations where browser auth is unnecessary.
- Store extracted content and extraction metadata as durable article state.
- Record extraction attempts and failures through the pipeline attempt model.
- Add local hosted article pages using stable article identifiers.
- Re-render generated feed item snapshots after extraction succeeds when output feed settings use extracted content or hosted links.

## Semantic Filtering And Summarization

- Add filtering step implementations after extraction produces reliable article content.
- Add summarization step implementations after filtering and extraction are observable.
- Store model, prompt/config, output, confidence, and rationale for LLM-backed steps.
- Keep source-specific policies auditable and correctable.
- Avoid automatic destructive filtering until review behavior is clear.

## Morning Newspaper

- Define newspaper sections and selection policies on top of extracted and enriched article state.
- Render an iPad-friendly HTML/PDF artifact.
- Add email delivery once the PDF output is useful.
- Add Home Assistant/MQTT controls and status sensors when newspaper runs exist.
- Add print support only after the PDF workflow proves valuable.

## World Radar

- Add broader source pools only after the personal reading pipeline is reliable.
- Cluster related coverage across sources.
- Summarize consensus, disagreement, and story movement.
