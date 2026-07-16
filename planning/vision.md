# Personal News Intake

## Purpose

Build a local-first personal news intake system that improves the existing FreshRSS and Reeder workflow by adding an upstream layer for feed aggregation, deduplication, generated feed publishing, content extraction, semantic filtering, summarization, and morning newspaper generation.

The morning newspaper is the long-term product goal. The intermediate feed features are intentionally useful on their own, and each one should move the system closer to that final newspaper workflow.

## First Useful Product

The feed foundation is generated RSS feeds.

The app should keep input feeds, intake groups, canonical articles, and generated output feeds as separate concepts. Reeder Classic remains the primary reading client through FreshRSS for the bulk of news consumption.

Reliable extraction across static, JavaScript-rendered, and authenticated sources is the foundation for local-LLM summarization and filtering. The next compelling product milestone is useful AI digestion on successfully extracted articles; complete browser coverage does not need to block learning from sources that already extract cleanly.

## Product Modes

### Generated Feed Curation

Generated feed curation is the initial product mode.

- Subscribe to multiple source feeds and sub-feeds.
- Group related input feeds into intake groups.
- Deduplicate repeated articles within intake groups.
- Preserve where each article appeared.
- Publish output feeds from the post-intake article pool.
- Use output feeds primarily for categories while keeping the mechanism generic.
- Leave room for future filtering and routing policies.
- Publish generated RSS feeds for FreshRSS.
- Keep generated feeds useful without LLM processing.

### Content Extraction

Browser extraction expands coverage beyond sources that work through direct HTML fetches.

- Reuse authenticated browser sessions where needed.
- Render JavaScript-dependent pages in isolated browser contexts.
- Surface auth expiration and browser failures clearly.
- Learn the cheapest useful extractor for each site without treating transient failures as capability failures.

### Semantic Filtering And Enrichment

Semantic filtering and enrichment come after the feed pipeline and extraction path are reliable.

- Classify articles into durable labels and categories.
- Filter unwanted coverage based on meaning, topic, and framing, not brittle keywords.
- Support source-specific content policies, such as excluding political-topic coverage from otherwise useful sources whose political coverage is not trusted.
- Store confidence, rationale, model identity, prompt/config metadata, and review state.
- Make bad decisions auditable and correctable.

### Morning Newspaper

The morning newspaper is the end goal, built on the same article pipeline after the feed, extraction, and enrichment pieces are reliable.

- Generate an iPad-friendly PDF.
- Email the PDF when enabled.
- Include sections such as tech, science, finance, cars, local, culture, and longform.
- Use clickable links to original articles and local article pages.
- Consider printing only after the PDF workflow proves useful.

### World Radar

World Radar is a future mode that summarizes broad world events from a larger source pool. It should cluster coverage across sources and identify consensus, disagreement, and story movement. It should not replace the curated personal reading pipeline.

## Guiding Principles

- Keep FreshRSS and Reeder as the downstream reading workflow.
- Make generated RSS feeds valuable before adding AI-dependent behavior.
- Keep intake grouping/dedupe separate from output feed categorization/filtering.
- Make processing steps configurable in the UI from the beginning.
- Treat each intermediate feature as a useful standalone capability and as progress toward the morning newspaper.
- Use the app as the owner of durable state, orchestration, and operator visibility.
- Treat worker tools as replaceable transforms with explicit contracts when a separate executable boundary is justified.
- Prefer observable failures over silent omissions.
- Keep planning docs implementation-agent-agnostic.
