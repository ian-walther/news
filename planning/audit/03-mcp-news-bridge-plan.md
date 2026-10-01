# News MCP Bridge Plan Audit

Scope: the revised [MCP bridge proposal](../mcp-news-bridge.md), with line
references to the working-copy plan reviewed on 2026-10-01.

The plan is ready to implement after the two small contract clarifications
below. Neither needs another product decision or additional infrastructure.
Keep stable finding IDs and remove findings once their contracts are folded
into the proposal; do not retain a completed-work log.

## Implementation Boundary

The bridge is straightforward retrieval. All editorial decisions belong in
the consuming agent's prompt, not Phoenix or the MCP server.

Follow the plan's explicit live-read and LAN-trust decisions. Do not reintroduce
snapshots, stored exports, internal authentication, or network isolation to
resolve these findings. Preserve separate readable and coverage windows,
independence from digestion and RSS publication, and real-client verification
of payload and context limits rather than assumed guarantees.

## Remaining Findings

### MCP-07: Continuation requests must inherit omitted cursor parameters

- Severity: Medium. Type: continuation contract clarification.
- Plan: Window, lines 119-121; Cursor, lines 161-166.
- Problem: `until` defaults to the current call time, while the cursor is
  bound to the original window. Applying that default again on a continuation
  request can reject a valid cursor even though the caller did not explicitly
  change any parameters.
- Required clarification: resolve defaults on the first request. On a
  continuation request, inherit omitted window, feed-selection, and budget
  parameters from the cursor; reject explicitly conflicting values and
  malformed cursors. Apply the same principle to index pagination and its
  bound parameters. Keeping a query window fixed does not create a snapshot:
  the plan's live-read limitations still apply.
- Acceptance: a request with an omitted `until` returns a cursor that can be
  used later without repeating the resolved timestamp. Matching explicit
  parameters work; conflicting ones fail clearly. Defaults must not silently
  replace cursor-bound values.

### MCP-05: Define failure when framing leaves no room for article text

- Severity: Medium. Type: remaining payload-budget clarification.
- Plan: Budget accounting, lines 153-160; result framing, lines 193-196.
- Problem: headers, framing, and the printed cursor count toward `max_chars`.
  A long title, URL, or feed list can exhaust the budget before any article
  text fits. Splitting the body does not solve that case.
- Required clarification: return an explicit "budget too small" error when
  required framing cannot fit with any body text. Never silently truncate
  information, exceed the declared budget, or return a continuation that makes
  no progress. The error should explain that the caller needs a larger budget
  and must start a new request if the existing cursor binds the old budget.
- Acceptance: cover long headers and cursors at a small otherwise-valid
  budget. A nonterminal success must advance through the selected articles or
  through an oversized article's text; otherwise it must fail explicitly.

## Handoff

Fable can incorporate these two details and proceed within the existing plan.
Do not reopen the architecture or expand the editorial scope. This audit is
a plan review, not an implementation sign-off or authorization to change
public networking.
