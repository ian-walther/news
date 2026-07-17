# Architecture

## Direction

The system should be a Phoenix application named Newspaper, with LiveView for the web UI and plain Phoenix controllers for generated feeds, article pages, health checks, and simple APIs.

Phoenix and LiveView are intentional choices. They match the user's work stack and another active side project, so the app should lean into that ecosystem rather than treating the UI framework as an open question.

The Phoenix control plane owns configuration, orchestration, durable data, workflow state, generated RSS endpoints, local article pages, and later PDF/email/print outputs.

Job scheduling/orchestration should use ordinary supervised Elixir processes, such as GenServers, rather than introducing Oban. This matches the user's existing experience and keeps the system familiar. A Postgres-backed job system can be reconsidered later if the job surface grows enough to justify it.

Worker executables may perform specialized transformations, but they should not own durable application state. The processing pipeline should support both internal implementations and external worker-backed implementations behind the same step interface.

For extraction, the Phoenix control plane should own the escalation chain. Worker executables expose individual extraction strategies; the app decides which strategy to try, when to escalate, and what site-level policy to persist for future articles.

## Repository Layout

Keep the repository root as the operator surface.

```text
news/
  newspaper/      Phoenix application
  workers/        external pipeline step implementations
  planning/       forward-looking planning docs
  scripts/        repo-level operational helpers
  Dockerfile
  docker-compose.dev.yml
  docker-compose.prod.yml
```

Docker and Compose files should stay at the root so production and development commands can run without path arguments. The Docker build context should remain the repository root because production images need the Phoenix app and, as extraction work begins, worker code.

The Phoenix app lives in `newspaper/`. Root-level scripts should wrap common Mix commands so day-to-day work can still begin from the repository base.

## Boundary Model

Use one control plane with clear worker boundaries.

```text
control plane
  -> calls worker or internal module
  -> validates result
  -> persists result
  -> advances workflow
  -> publishes feeds or queues next work
```

Avoid both of these failure modes:

- Multiple independent components directly mutating a shared domain schema.
- Scattered files on disk becoming the primary source of truth.

## Control Plane Responsibilities

- Source and feed configuration.
- Feed collection.
- Canonicalization and deduplication.
- Generated RSS feed publishing.
- Workflow state and failure visibility.
- Operator/admin UI.
- Retry and audit history.
- Local article pages once extraction exists.
- Later paper planning, delivery, and Home Assistant integration.

Operator-facing views should lead with domain state and meaningful parent operations. Low-level child runs, snapshots, and raw metadata remain available as expandable debug evidence instead of dominating routine workflows. Time values should be stored in UTC and rendered in the operator's browser-local timezone.

## Worker Responsibilities

Workers should receive explicit structured input and return explicit structured output when they exist. Extraction establishes the initial worker precedent: versioned JSON requests arrive on stdin, versioned JSON responses leave on stdout, diagnostics use stderr, and durable state remains owned by the Elixir application.

- `news-extract-simple`: direct HTML fetch and extraction evidence.
- `news-extract-headless`: isolated headless browser rendering and extraction evidence.
- `news-extract-headed`: headed host Chrome extraction evidence.
- `news-classify`: semantic labels, confidence, routing/filter decision, rationale.
- `news-render-paper`: PDF rendering from a complete layout model.

Workers should write logs to stderr, return machine-readable output on stdout or an output file, and avoid mutating durable app state directly.

Extraction workers should share the same app-facing interface. The implementation key should be part of the request and response, but the response shape should stay stable across simple HTML, headless browser, and headed browser extraction.

Direct-HTML and isolated-headless workers belong inside the production app image so deployment remains self-contained. Persistent authenticated Chrome remains host-owned because its profile and visible desktop session are long-lived operator-managed capabilities.

The first article-digest implementation should not add a worker executable. Ollama is already an external HTTP model runtime, so the Phoenix application should use `Req` to call a configurable Ollama base URL directly. The app owns model discovery, selected-model configuration, structured-output validation, durable digest state, attempts, and failures.

## Pipeline Implementation Registry

Pipeline step implementations should be registered in application code.

The registry should provide:

- implementation key
- step type
- label and description
- config schema
- validation rules
- runtime module or worker command

The admin UI should use registry metadata to render configurable pipeline step forms. The database should store selected implementation keys and config, while code controls which implementations are available.

Extraction has two distinct registry roles. An output feed selects the `extraction.site_policy` pipeline coordinator to participate in extraction; it does not select an extractor. The host-keyed site policy selects the starting extractor and owns escalation, pacing, timeout, and content-quality thresholds.

The extraction registry should include at least:

- `extraction.simple_html`
- `extraction.headless_browser`
- `extraction.headed_browser`

The registry describes available implementations. Site extraction policy describes where in the chain a site should start.

The digestion registry should initially include only:

- `digestion.ollama.article_digest`

Its config schema should require an Ollama model name discovered from the configured server. Prompt and output-schema revisions remain code-owned so persisted artifacts can identify their behavior without creating a general database-defined prompt system.

## Browser And Auth Strategy

Authenticated extraction is important, but not required for feed aggregation.

Preferred extraction approach:

- Run a persistent Xorg desktop session on the production host.
- Use an Xorg dummy display configuration, not a physical display requirement.
- Run Chrome as a normal headed browser in that desktop session.
- Keep Chrome always running via systemd.
- Use a dedicated Linux user and dedicated Chrome profile for this project.
- Share the existing X display with `x11vnc` for occasional maintenance from macOS.
- Let the app or extraction worker connect to host Chrome over a secured local CDP endpoint.
- Keep Chrome remote debugging narrowly bound and firewall protected.
- Mark auth and extraction failures in app-owned state.

## Data Storage Direction

Use Postgres as the only supported database backend.

Database location should be configuration, not architecture. Both development and production should point the app at Postgres through a database URL.

Expected modes:

- Local development can use a Dockerized Postgres instance.
- Initial production can use an app-specific Docker Compose Postgres service.
- Later production can move to a shared network Postgres instance used by multiple self-hosted apps.

The application should be free to use normal Postgres and Ecto capabilities without preserving SQLite compatibility.

## Deployment Direction

Use two explicit modes:

- Native local development on the Mac.
- Docker Compose deployment for the target host.

The app should be deployable from the start while keeping local development painless.

Local development should run the Phoenix app natively on the Mac, with Docker used only to provide Postgres through a dev Compose file.

Production should use a real Docker image for the Phoenix app and a production Compose file. Initial production can include an app-specific Postgres service; later production can point the same app image at a shared network Postgres instance by changing the database URL.

Expected files from the start:

- `Dockerfile` for the production Phoenix app image.
- `docker-compose.dev.yml` for local development Postgres.
- `docker-compose.prod.yml` for production app deployment with app service and initial Postgres service.
- `.env` or documented environment files for dev/prod settings.

Host Chrome should remain outside Docker for persistent auth and interactive debugging. Isolated headless Chromium belongs inside the app image and must not reuse the host profile.

See `planning/prod-topology.md` for the current production topology decision.

## Home Assistant And MQTT

Home Assistant and MQTT belong in the project, but not in the immediate pipeline/extraction work.

The user already runs an MQTT server and has another side project that publishes Home Assistant entities. This integration should be treated as a normal later system integration, not an exotic add-on. It becomes relevant when the morning newspaper, email, print controls, and run-status sensors are underway.
