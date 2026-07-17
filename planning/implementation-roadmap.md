# Implementation Roadmap

## Content Extraction

- Audit simple extraction against representative articles from configured sources.
- Improve quality classification using observed paywalls, login pages, JavaScript shells, and incomplete output.
- Add the persistent headed browser implementation through host Chrome/CDP.
- Exercise headless-to-headed escalation with real authenticated or browser-state-dependent failures.

## Article Digestion

- Add a configurable Ollama connection and live model discovery in the admin UI.
- Add `digestion.ollama.article_digest` for successfully extracted articles.
- Request and validate one structured factual title and summary.
- Store the input extraction identity, selected model, prompt/schema version, config snapshot, output, and validation/debug metadata.
- Add explicit output-feed title and body source selectors.
- Make future processing automatic and existing-article digestion an explicit bulk action.

## Semantic Filtering

- Add filtering implementations after extraction and digest model behavior are observable.
- Store model, prompt/config, decision, confidence, and rationale for LLM-backed filtering steps.
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
