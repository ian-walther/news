# News MCP Bridge Review Handoff

Use the [implementation review](04-mcp-news-bridge-implementation.md) for the
retrieval-contract regression requirements and review boundary. Keep the
[rollout plan](../mcp-news-bridge.md) as the authority for infrastructure
acceptance and Ian's approval boundaries.

Preserve cursor-only continuation, explicit too-small-budget errors, live
reads, and LAN trust. Remediation must not add snapshots, internal
authentication, or editorial processing. All editorial decisions belong in
the consuming agent's prompt.
