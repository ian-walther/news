# News MCP Bridge Implementation Review

Review target: `6362f27`. There are no remaining functional findings from
the six-point implementation audit in this targeted reconciliation. Keep
client integration and deployment acceptance separate from that conclusion.

## Review Boundary

This pass covers the retrieval contract: pagination, response-size accounting,
timestamp precision, metadata delivery, and result formatting. It excludes
authentication, authorization, public networking, and security-control testing.

The review uses local source inspection and application-level tests only.
No MCP server was started, no production endpoint was contacted, and no
application behavior was changed. The expanded MCP integration and protocol
tests are not claimed as executed by this reconciliation.

## Remaining Acceptance

Follow the [rollout plan](../mcp-news-bridge.md) for the remaining work:

- Verify the actual Claude and ChatGPT result-size limits, continuation
  behavior, metadata visibility, and structured/text-only compatibility.
- Retrieve a representative busy weekday through each intended client and
  compare the returned articles with the index, allowing for the documented
  limitations of separate live reads.
- Observe context handling and finish a complete reference-prompt run.
  Prompt quality remains the agent's concern, not a server feature.
- Keep identity-provider and public-route acceptance with Ian's explicit
  approval process. This functional review does not perform or waive those
  checks.

## Regression Requirements

Preserve these contracts in future implementation changes:

- Validate cursor-derived sizes against the configured limits, including
  cursors issued before limits change. Ordinary cursor-only continuation
  must retain its original window, feeds, and size.
- Decode invalid cursor data into typed client errors, not exceptions or
  misleading upstream-unavailable results.
- Count all rendered text against the budget, including preambles, metadata,
  empty-result messages, and terminal/continuation framing. A response that
  cannot fit must fail explicitly rather than truncate content.
- Preserve microsecond window precision through parsing, SQL comparison,
  cursor continuation, and explicit-parameter comparisons. Equivalent
  timezone offsets must select the same articles.
- Deliver publication, first-seen, first-extraction, and latest-extraction
  metadata in the agent-visible index. Article text must carry both
  extraction timestamps, and the index must remain body-free.
- Apply text-only mode consistently to successes and errors while retaining
  typed error information in text.

Keep retrieval naive and read-only. Do not add editorial processing,
snapshots, or delivery guarantees as part of these regression requirements.

## Verification Basis

Against the reviewed commit:

- 31 bridge-context and controller tests passed with seed 0.
- Four additional local, rollback-only fixture tests passed: microsecond
  readable/coverage agreement; fractional index continuation with equivalent
  timezone offsets; a shortened in-progress article's terminal page; and
  bounded empty results plus lossless single-article slices.
- The MCP package build passed.
- Direct result-helper checks passed for successful results and not-found,
  invalid-parameter, too-small-budget, and unavailable-upstream errors in
  both structured and text-only modes. These invoked functions directly,
  without a server or network calls.

This is not a full-suite, MCP transport, security, or production signoff.
Those boundaries are intentional for this review.
