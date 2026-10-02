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

Before client rollout, Astra verifies the corrections for the
[implementation audit](audit/04-mcp-news-bridge-implementation.md) and clears
its findings. Each finding has maintained tests named for it:

| Finding | Where to verify |
| --- | --- |
| MCP-IMP-01 cursor-inherited sizes | `bridge_test.exs` "cursor contents are untrusted"; `bridge_controller_test.exs`; integration test |
| MCP-IMP-02 malformed cursor fields | Same three; decoding is total in `Newspaper.Bridge.Cursor` |
| MCP-IMP-03 budget on every response shape | `bridge_test.exs` "the budget bounds every response shape"; controller and integration tests |
| MCP-IMP-04 fractional-second bounds | `bridge_test.exs` "fractional-second bounds keep their meaning"; integration test |
| MCP-IMP-05 timestamp metadata | `bridge_test.exs` "timestamp metadata reaches the reader"; integration test, both result modes |
| MCP-IMP-06 text-only errors | `mcp/tests/protocol/http.test.ts`, both eras; integration test |

The integration test is
`newspaper/test/newspaper_web/mcp_bridge_integration_test.exs`: the built MCP
server against the real read API.

### 1. Identity provider (Ian approves each change)

- Create an Auth0 API with identifier `https://news-mcp.ianwalther.com/mcp`,
  RS256, RBAC on, permissions in the access token, permission `news.read`.
  Grant `news.read` to Ian's user only.
- **Audience selection.** The tenant's default audience is the Trilium API,
  and MCP clients do not send `audience`. Enable and test Auth0's Resource
  Parameter Compatibility Profile so the OAuth `resource` parameter selects
  this API. Verify, from Claude and from ChatGPT: first authorization and
  token refresh; a Trilium token is rejected here and a News token is
  rejected at Trilium; the existing Trilium connector still works. Do not
  change the tenant default audience and do not accept the Trilium audience
  here. A second Auth0 tenant is the fallback if the profile cannot do this.
- Add the connector callback URLs for Claude and ChatGPT to the first-party
  application, as was done for the Trilium server.

### 2. Public route (Ian approves each change)

- OPNsense: add `news-mcp.ianwalther.com` to the shared certificate, and an
  nginx HTTP server, location, and upstream to the N150 on the MCP port, with
  proxy buffering off and bot protection off, mirroring the Trilium MCP
  entries. Only that port is proxied; no Phoenix route.
- Smoke test from outside: `/healthz` answers, an unauthenticated `POST /mcp`
  answers 401 with the protected-resource metadata URL, and the metadata
  document names the Auth0 tenant.

### 3. Client integration, recorded per client

For Claude and for ChatGPT, record in `docs/mcp-server.md`:

- connector authorization and token refresh working;
- the largest `max_chars` the client accepts in one result;
- whether the client continues correctly from the cursor, and whether it
  needs `MCP_RESULT_STRUCTURED=false`;
- one heavy weekday retrieved end to end, with the returned guids checked
  against `list_articles`;
- what the runtime does with context across pages. This is observed, not
  promised.

### 4. First scheduled job

- Run the reference prompt from `docs/mcp-server.md` as a scheduled agent on
  one client and adjust the prompt from what is learned. Prompt quality is not
  a server acceptance criterion.

## Sizing basis (production, 2026-10-01)

For choosing page budgets during integration: weekdays run 132–182 articles
and 620k–825k characters; weekend days 51–60 articles and about 320k
characters. Median article 3,364 characters, 90th percentile 8,492, largest
256,811.
