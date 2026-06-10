# Implementation Roadmap

## Phase 0: Planning And Scaffolding

- Create project planning docs.
- Use Newspaper as the Phoenix app/repo/project name.
- Use the spare Intel N150 Ubuntu Server machine as the initial production host.
- Decide first intake groups and V1 output feed semantics.
- Do a dedicated production architecture pass.
- Initialize git after planning and scaffold are ready.

## Phase 1: Phoenix Foundation

- Create Phoenix app named Newspaper with LiveView.
- Add Postgres database layer configured by database URL.
- Add an empty seed mechanism for initial setup/dev fixtures.
- Add basic admin shell with Failures / Recent Activity as the landing page.
- Add `docker-compose.dev.yml` for local development Postgres.
- Add production `Dockerfile`.
- Add `docker-compose.prod.yml` for production app plus initial app-specific Postgres.
- Keep local development native on Mac.
- Document production environment variables and service boundaries.

## Phase 2: Feed Aggregation

- Add source feed configuration.
- Add intake group configuration.
- Keep V1 intake group and input feed forms minimal: group name, feed name, feed URL, group assignment, enabled flag.
- Fetch RSS and Atom feeds.
- Store raw feed items.
- Record fetch runs and failures.

## Phase 3: Canonicalization And Deduplication

- Normalize URLs.
- Strip tracking parameters.
- Resolve simple duplicate cases within intake groups.
- Preserve source appearances.
- Add operator visibility for dedupe decisions.

## Phase 4: Generated Feed Publishing

- Define generated feeds.
- Select canonical articles from the article pool for output feeds.
- Render RSS output.
- Subscribe FreshRSS to generated feed endpoints.
- Confirm Reeder workflow.

## Phase 5: Optional Content Extraction

- Define extraction worker contract and separate-executable precedent.
- Set up persistent host browser environment on the N150.
- Add extraction status and failure UI.
- Connect to headed host Chrome over secured local CDP.
- Parse article content.
- Replace generated feed item body when extraction succeeds.

## Phase 6: Semantic Enrichment

- Add local LLM classification.
- Store labels, confidence, rationale, and filter decisions.
- Add review/correction flow.
- Add summaries where useful.

## Phase 7: Morning Newspaper

- Plan paper sections and selection rules.
- Render HTML/CSS to PDF.
- Email PDF for iPad reading.
- Add Home Assistant/MQTT controls and status sensors where useful.
- Add optional print path only after PDF proves useful.

## Phase 8: World Radar

- Add larger source pool.
- Cluster related stories.
- Summarize consensus, disagreement, and story movement.
