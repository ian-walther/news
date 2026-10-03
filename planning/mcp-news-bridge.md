# News MCP Bridge: Rollout

The bridge itself is built and documented in
[`docs/mcp-server.md`](../docs/mcp-server.md): an OAuth-protected MCP server
(`mcp/`) over a Phoenix read API (`Newspaper.Bridge`), returning full article
text for a time window in bounded pages. This document holds only what is
left before Ian's agents can use it.

## Roles

- **Ian** owns product decisions and approves every public-network and
  identity-provider change.
- **Fable** implements, following `AGENTS.md`.
- **Astra** audits against this plan and `docs/mcp-server.md`. Findings go in
  `planning/audit/` with stable IDs.

## Standing decisions

These govern any further work on the bridge:

- It is **interim** and deliberately naive: retrieval only. All editorial
  behavior belongs in the consuming agent's prompt. No ranking, clustering,
  summarizing, job runner, notes service, or edition publishing is added.
- **Live reads, no guarantees.** No snapshots, stored exports, or delivery
  checkpoints.
- **OAuth is the only security layer.** No internal token, gateway, or
  network isolation between the MCP server and the application.
- **Both Claude and ChatGPT** are target clients.
- Public URL: `https://news-mcp.ianwalther.com/mcp`, which is also the Auth0
  API identifier.
- It must stay removable without touching ingestion, extraction, RSS
  identity, or the Newspaper domain. It is removed when Ian no longer wants
  external-agent retrieval; there is no expiry date.

## Remaining work

Keep the [implementation review's regression requirements and verification
boundary](audit/04-mcp-news-bridge-implementation.md) separate from the
remaining rollout acceptance below. A functional review does not replace
real-client or deployment checks.

### 1. Remaining client acceptance

Use the production routing and identity configuration documented in
[`docs/mcp-server.md`](../docs/mcp-server.md#production-routing-and-identity)
and the recorded bounded client checks in its client-observations section.
Preserve existing callback URLs and do not store credentials in the repo.

Keep rollout verification to ordinary client authorization, refresh, and
read operations. Adversarial authorization testing and cross-service token
probes are outside this rollout's scope.

For Claude and for ChatGPT, record in `docs/mcp-server.md`:

- token refresh after the access token expires;
- a normal read from the existing Trilium connector still working;
- practical index and text-page capacities beyond the conservative prompt
  settings, without assuming the server's maximum fits a client;
- one heavy weekday retrieved end to end, with the returned guids checked
  against `list_articles`;
- what the runtime does with context across pages. This is observed, not
  promised.

### 2. First scheduled job

- Run the reference prompt from `docs/mcp-server.md` as a scheduled agent on
  one client and adjust the prompt from what is learned. Prompt quality is not
  a server acceptance criterion.
- Choose the client, schedule, and editorial preferences with Ian before
  creating the job.

## Sizing basis (production, 2026-10-01)

For choosing page budgets during integration: weekdays run 132–182 articles
and 620k–825k characters; weekend days 51–60 articles and about 320k
characters. Median article 3,364 characters, 90th percentile 8,492, largest
256,811.
