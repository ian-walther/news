# Implementation Roadmap

## Content Extraction

- Audit simple extraction against representative articles from configured sources.
- Improve quality classification using observed paywalls, login pages, JavaScript shells, and incomplete output.
- Add the persistent headed browser implementation through host Chrome/CDP.
- Exercise headless-to-headed escalation with real authenticated or browser-state-dependent failures.

## Digestion Evaluation

- Pilot `qwen3.6:27b` digest titles and summaries in one real Reeder feed.
- Compare alternate models only when representative pilot output exposes a specific weakness.
- Tune prompt wording, summary length, and validation bounds from observed output.
- Add automatic digestion retries only when observed failure classes justify a bounded policy.
- Add review or correction controls only when repeated use demonstrates a concrete workflow.

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
