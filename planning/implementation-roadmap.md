# Implementation Roadmap

## Content Extraction

- Audit simple extraction against representative articles from configured sources.
- Improve quality classification using observed paywalls, login pages, JavaScript shells, and incomplete output.
- Add the isolated headless browser implementation behind the shared JSON contract.
- Add the persistent headed browser implementation through host Chrome/CDP.
- Exercise app-owned escalation and site-level minimum implementation learning with real failures.

## Semantic Filtering And Summarization

- Add a first local-LLM summarization implementation for successfully extracted articles.
- Add filtering implementations after extraction and model output are observable.
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
