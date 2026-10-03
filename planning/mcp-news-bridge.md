# News MCP Bridge: Rollout

The bridge itself is built and documented in
[`docs/mcp-server.md`](../docs/mcp-server.md): an OAuth-protected MCP server
(`mcp/`) over a Phoenix read API (`Newspaper.Bridge`), returning full article
text for a time window in bounded pages. This document records why it is
parked and what a resumption would need.

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

## Status: parked (2026-10-03)

The bridge is deployed, routed, and connected to Claude and ChatGPT, and the
full-day retrieval works at the transport level (see the client observations
in `docs/mcp-server.md`). The daily run itself does not: a weekday's full
text is more than either client digests in one job. No further rollout work
is planned until the design is reworked.

## When resumed

Rework the bridge to pass less information per run before any client work
resumes. Candidates, undecided: smaller work units (per feed or per
sub-window runs that each produce a partial result), a body-free first pass
with selective `get_article` reads, or server-side reduction, which would
revisit the "retrieval only" standing decision. Ian decides which; the
sizing basis below is the input.

## Sizing basis (production, 2026-10-01)

For choosing page budgets during integration: weekdays run 132–182 articles
and 620k–825k characters; weekend days 51–60 articles and about 320k
characters. Median article 3,364 characters, 90th percentile 8,492, largest
256,811.
