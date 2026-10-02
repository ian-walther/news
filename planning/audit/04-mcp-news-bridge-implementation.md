# News MCP Bridge Implementation Audit

Review target: `2ceb600c2e5b9136dacb5611cbdf4b17a38ecb0e`, against the
[retrieval contract](../../docs/mcp-server.md) and
[standing decisions and rollout plan](../mcp-news-bridge.md).

The architecture does not need to be redesigned. Six implementation findings
remain. Address the cursor, budget, and time-window findings before treating
the retrieval contract as ready for client rollout. None needs a new product
decision. Preserve these IDs during reconciliation and remove findings when
their fixes have been independently verified; do not turn this document into
a completed-work log.

## Findings

| ID | Priority | Required correction |
| --- | --- | --- |
| MCP-IMP-01 | P2 | Enforce size limits on values inherited from cursors |
| MCP-IMP-02 | P2 | Reject malformed cursor fields without raising exceptions |
| MCP-IMP-03 | P2 | Enforce the text budget on empty and exhausted bundle pages |
| MCP-IMP-04 | P2 | Preserve the meaning of fractional-second window bounds |
| MCP-IMP-05 | P2 | Deliver extraction-time metadata to the consuming agent |
| MCP-IMP-06 | P3 | Make text-only mode apply to error results too |

### MCP-IMP-01: Cursor-derived sizes skip the configured limits

**Locations:** `newspaper/lib/newspaper/bridge/cursor.ex:24-38`;
`newspaper/lib/newspaper/bridge.ex:775-794`;
`mcp/src/mcp/tools.ts:74-101`.

The cursor decoder checks only that `size` is an integer. When the caller
omits an explicit `limit` or `max_chars`, `resolve_size/4` accepts that integer
without checking the same bounds used for first-page requests. The MCP input
schema cannot protect this path because it sees only an opaque cursor string.

**Reproduction:** in the rollback-only local test database, create an
extracted article with 330,000 characters. Obtain a bundle cursor with
`max_chars: 2000`. Decode its base64url JSON, change `size` to `400000`,
re-encode it, and submit a cursor-only continuation. It succeeds despite the
configured maximum of 320,000. The actual MCP-to-Phoenix test returned 329,508
characters, not an error. An index cursor with `size: 301` is likewise
accepted despite the maximum of 300. An index cursor with `size: 0` and a
nonempty result raises when cursor generation accesses the nonexistent last
item of the empty page.

**Impact:** the advertised response and query limits are not invariants.
Invalid inherited sizes can also turn a read into a server error. This is a
validation defect, not a reason to add another authentication layer.

**Required correction:** validate resolved sizes regardless of whether they
come from explicit arguments or a cursor. Reject out-of-range inherited
values with a typed client error. An unsigned cursor is acceptable if all of
its contents are treated as untrusted arguments; signing is not required to
solve this finding.

**Regression criteria:** test zero, negative, and above-maximum sizes for
both cursor kinds, including a cursor issued before a configured limit was
lowered. Exercise at least one rejected continuation through the controller
and real MCP transport. Ordinary cursor-only continuation and matching
explicit parameters must still work.

### MCP-IMP-02: Malformed cursor fields become exceptions and upstream outages

**Locations:** `newspaper/lib/newspaper/bridge/cursor.ex:24-41`;
`newspaper/lib/newspaper/bridge.ex:181-185,403-408`;
`newspaper/lib/newspaper_web/controllers/bridge_controller.ex:12-22`.

Base64 and JSON validation are insufficient. The decoder calls date parsers
before checking field types, calls `Enum.all?/2` on a potentially non-list
`feeds` value, and accepts any map as `pos`. The query/resume code then
assumes required position fields and valid values.

**Reproduction:** start with a correctly encoded cursor and independently
replace these fields, preserving the tool kind and version:

| Change | Observed outcome |
| --- | --- |
| `feeds: "not-a-list"` | `Protocol.UndefinedError` |
| Index `pos: {}` | `FunctionClauseError` |
| Index `pos: {"t": "yesterday", "a": 0}` | `MatchError` |
| `since: 42` | `FunctionClauseError` in date parsing |

The empty index-position case was also sent through a local MCP client to
the actual Phoenix API. Phoenix produced a 500; MCP reported
`UPSTREAM_UNAVAILABLE`, misclassifying bad input as an unavailable service.

**Required correction:** make cursor decoding total and non-raising for
untrusted JSON. Validate container types, required fields, and each kind's
position schema before querying. Check timestamp, article/feed identifiers,
offset, and part-number types and valid ranges. Return `INVALID_CURSOR`
through the existing error envelope rather than masking arbitrary exceptions
with a broad catch around the whole request.

**Regression criteria:** malformed-but-valid JSON must produce a typed 400
at Phoenix and `isError` with `INVALID_CURSOR` at MCP, not a 500 or an
upstream-unavailable error. Cover both cursor kinds, missing fields, wrong
types, invalid nested dates, and invalid position values. Keep this distinct
from MCP-IMP-01: structurally valid integers still need bound checks.

### MCP-IMP-03: Empty bundle pages can exceed their declared budget

**Locations:** `newspaper/lib/newspaper/bridge.ex:291-322,330-331,475-477`;
`newspaper/lib/newspaper/bridge.ex:898-899`.

`bundle/1` subtracts the preamble and footer reserve before filling articles,
but the empty-list clause of `fill/7` succeeds even when the remaining room
is negative. The final response has no whole-result size check. The
empty-result message is also appended outside article budget accounting.

**Reproduction:** create 12 output feeds with valid titles of approximately
200 characters each, select those feeds, and request an empty extraction
window with `max_chars: 2000`. For the fixture using `"Cars "` repeated 40
times followed by each feed number, the successful response was 2,695
characters. Every feed title is below the database's 255-character limit.

**Impact:** a valid request can violate the hard text budget even with no
article bodies. The explicit too-small-budget handling covers an article's
header, but not every response shape.

**Required correction:** include all framing, the empty-result message, and
the actual terminal/continuation footer in the bound. Return
`BUDGET_TOO_SMALL` when mandatory framing cannot fit; do not silently truncate
metadata or report an oversized success. Generalize the error wording so it
also makes sense when there is no article header.

**Regression criteria:** cover empty windows, feed filters matching no
articles, and continuations exhausted by deletion or shorter replacement
text. Every successful response must satisfy
`String.length(text) == chars` and `chars <= max_chars`, including terminal
pages. Live-read changes are allowed; oversized results are not.

### MCP-IMP-04: Fractional-second cutoffs silently change the selected window

**Locations:** `newspaper/lib/newspaper/bridge.ex:669-677,684-707`.

Both explicit timestamps and decoded cursor window bounds are truncated to
whole seconds. The contract accepts ISO-8601 timestamps with an explicit
offset and defines an exact half-open interval; it does not specify silent
rounding. Whole-second storage does not make fractional query bounds
equivalent to their truncated values.

**Reproduction:** give an article a first extraction of
`2026-09-30T12:00:00Z`. Request a bundle starting at
`2026-09-30T12:00:00.500Z`. The article is returned even though it falls
before `since`. No concurrent mutation is involved.

**Impact:** ordinary client timestamps containing milliseconds can include
the wrong boundary article or exclude one at the other end. Two explicitly
different continuation timestamps within one second can also be treated as
equal. This is separate from the accepted limitations of live paging.

**Required correction:** preserve the actual bounds through parsing, cursor
encoding/comparison, and database parameter typing. If precision is
intentionally restricted instead, reject unsupported precision explicitly
and document that restriction; never silently reinterpret the window.

**Regression criteria:** verify both inclusive `since` and exclusive `until`
with fractional seconds, equivalent timezone offsets, and cursor-only
continuation. An article exactly at noon must be excluded by a start at
noon plus 500 ms and included by an end at noon plus 500 ms. Explicitly
conflicting cursor parameters must remain distinguishable.

### MCP-IMP-05: Timestamp metadata is assembled but not delivered to MCP clients

**Locations:** `newspaper/lib/newspaper/bridge.ex:123-135,245-269,492-508`;
`mcp/src/mcp/tools.ts:153-159`.

Phoenix's article index contains `first_seen_at`, `first_extracted_at`, and
`last_extracted_at`, but its rendered text includes only publication time.
The MCP handler discards the index's article metadata array and forwards only
the rendered text, window, totals, and cursor. Bundle and single-article
headers include first extraction, but still omit latest extraction. The
documented distinction between first and latest extraction is therefore not
fully visible to the consuming agent.

**Reproduction:** use separate timestamps for publication, first seen, first
extraction, and latest extraction. In the actual local HTTP/MCP probe,
Phoenix returned `first_seen_at: 2026-09-30T12:00:11Z` and
`last_extracted_at: 2026-09-30T12:00:42Z`. Neither appeared anywhere in the
MCP `list_articles` result. Its structured keys were only `window`, `totals`,
and `next_cursor`.

**Required correction:** expose the relevant factual timestamps in the
agent-visible index and latest extraction in article metadata. Rendering
them in Phoenix's text preserves the thin MCP adapter and also works in
text-only mode. Do not add a duplicate full-text payload or any editorial
processing to solve this.

**Regression criteria:** assert metadata presence in actual MCP results,
not just Phoenix JSON. Use distinct fixture timestamps so publication time
cannot accidentally satisfy another timestamp assertion. Verify structured
and text-only modes and keep the index body-free.

### MCP-IMP-06: Text-only mode still returns structured errors

**Locations:** `mcp/src/mcp/results.ts:15-33`;
`mcp/src/mcp/server.ts:100-125`.

`textResult/3` respects `MCP_RESULT_STRUCTURED=false`, but `fail/2` always
attaches `structuredContent`. The advertised compatibility switch therefore
works for successful results only.

**Reproduction:** initialize the MCP server with
`MCP_RESULT_STRUCTURED=false`, then call `get_article` for a missing guid.
The result has `isError: true` and still includes
`structuredContent.error.code: "NOT_FOUND"`. This was observed through the
local MCP protocol, not just by inspecting the helper.

**Impact:** a client that needs the compatibility setting can still encounter
the incompatible result shape on a routine error. No claim is made that
either target client currently requires this setting; live integration is
still pending.

**Required correction:** apply the result-format setting consistently to
application-generated error results, keeping `isError` and the readable
text error payload.

**Regression criteria:** with the switch off, successful calls and tool
errors must omit `structuredContent`. Cover not found, invalid window,
too-small budget, schema validation, and upstream unavailability in both
supported protocol eras.

## Boundaries To Preserve

Do not expand remediation into these accepted product or architecture choices:

- Keep retrieval naive. Ranking, synthesis, relevance, and editorial
  decisions belong entirely in the agent prompt.
- Keep live reads. Concurrent re-extraction, feed-membership changes, and
  differences between separate index/bundle calls do not justify snapshots
  or exactly-once delivery machinery.
- Keep the agreed LAN trust boundary. An unauthenticated internal read API
  and MCP access to the application network are deliberate decisions, not
  findings in this review.
- Preserve first-successful-extraction selection, the separate first-seen
  coverage set, and independence from digestion and RSS publication.
- Preserve cursor-only continuation and explicit parameter-conflict errors.
  The findings concern validation and precision, not that interaction model.
- Preserve explicit too-small-budget errors. Extend their coverage rather
  than dropping metadata, truncating article text, or returning a cursor
  without progress.

## Verification And Reconciliation

Evidence for this review: the existing root test suite passed with 229
Elixir tests, 25 worker tests, and 32 MCP tests. MCP type checking, lint,
format checking, and a separate build passed. Those results are a baseline,
not evidence that the cases above are handled.

Independent checks used rollback-only local database fixtures and a local
MCP client connected to the actual Phoenix read API. The reproduced
cursor, size, empty-page, and time-boundary cases fail assertions for the
intended behavior. Metadata loss and text-only error formatting were
observed in real protocol results. No production data was mutated, and no
application fixes are included in this audit handoff.

Read-only deployment inspection found the production checkout at the
reviewed commit, healthy app/MCP/Postgres containers, and an MCP health
response reporting Phoenix reachable. This does not establish working OAuth
authorization or compatibility with either target client.

For each finding, first reproduce it in a maintained focused test, then fix
it and rerun the focused tests and full root suite. Include a real
Phoenix-to-MCP integration check: the current sidecar protocol tests use a
fake upstream, which cannot expose every contract mismatch between layers.
Use ordinary valid inputs as controls alongside malformed-input tests.

The remaining Auth0 audience/resource negotiation, token refresh,
cross-resource token rejection, public proxy, and Claude/ChatGPT payload and
continuation checks remain explicit rollout acceptance work. They were not
performed here and are not waived by this audit. Public-network and identity
provider changes still require Ian's approval.
