# News MCP Bridge Plan Audit

Scope: [the MCP bridge proposal](../mcp-news-bridge.md), checked against the
current extraction persistence, publishing behavior, router, and deployment
layout. This is a plan-reconciliation handoff to Fable, not authorization to
implement the MCP server or change public networking. References identify the
working-copy proposal reviewed on 2026-10-01. Production sizing figures are
taken from the proposal, not independently remeasured for this audit.

Use stable `MCP-NN` finding IDs. Reconcile the missing contracts into the main
proposal, then remove resolved findings from this document rather than keeping
a completed-work log. Recommendations below are not additional product
decisions attributed to Ian.

## Product Boundary

Ian's explicit clarification governs this review: **the bridge is a fairly
naive return of information. All editorial behavior belongs in the consuming
agent's prompt.**

- Return existing extracted full text, source metadata, explicit selection
  results, and mechanical continuation information.
- Keep date/feed filtering, deterministic ordering, article-GUID deduplication,
  pagination, and authentication in the bridge. These are retrieval mechanics,
  not editorial judgment.
- Do not add relevance scoring, story clustering, semantic deduplication,
  prioritization, source weighting, summaries, personalization, or editorial
  section assignment to Phoenix or the sidecar for this feature.
- The agent prompt owns what matters, how overlapping reports are combined,
  what gets omitted, the brief's length and structure, and citation style.
  Supply source URLs and stable GUIDs so it can make those choices.
- Do not build a job runner, prompt-management system, notes service, or
  edition-publishing model as a prerequisite for the bridge.
- A reference agent prompt may demonstrate usage, but editorial quality is
  not an MCP server acceptance criterion. Server acceptance concerns faithful,
  complete, bounded, authorized retrieval. Runtime feasibility is a separate
  integration check.

The thin TypeScript sidecar, Elixir-owned data selection, full-text output,
read-only tool surface, and independence from local digestion fit this scope.
Do not turn reconciliation into a redesign of the future Newspaper product.

## Findings

### MCP-01: Latest extraction time does not mean first became readable

- Severity: High. Type: daily-window correctness.
- Plan: lines 117-120 and 247-249.
- Evidence: `newspaper/lib/newspaper/content.ex:601-623` updates the existing
  extraction row, including `content_text` and `extracted_at`, on each
  successful extraction. The row is unique per article, not an immutable
  extraction event.
- Problem: re-extracting an old article makes it eligible for another daily
  window. The promise of neither missing nor repeating an article does not
  follow from this clock. Adjacent windows also need an explicit boundary
  convention.
- Recommendation: use a durable first-successful-extraction timestamp for
  normal daily inclusion, with half-open `[since, until)` intervals and
  explicit timezone offsets. Reuse an existing timestamp only after verifying
  that its lifecycle really preserves first success. Return publication time
  and latest extraction time separately as metadata. Re-extraction should not
  silently count as new news; an updates mode is not needed for this bridge.
- Guardrails: late extraction of an older article; successful re-extraction
  on a later day; an article exactly at a cutoff; multiple articles with equal
  timestamps; retries spanning a cutoff. Document any remaining limitations
  around concurrent commits instead of promising unconditional exactly-once
  delivery across independent daily jobs.

### MCP-02: A fixed upper time bound does not freeze a paged export

- Severity: High. Type: snapshot and cursor correctness.
- Plan: lines 121-133, 199-202, and 207-210.
- Evidence: the extraction upsert above replaces text in place. Article
  metadata and output-feed memberships can also change between reads.
- Problem: an `until` value only constrains a query. A re-extraction can move
  an article outside that query, change its text halfway through chunking, or
  change page sizes. Separate index and bundle requests can disagree even if
  they use the same time bounds. Switching to first-extraction time alone
  does not freeze bodies or memberships.
- Recommendation: define an export identity that fixes selected article
  GUIDs, ordering, feed metadata, and the text being paged. The index and
  bundles should refer to that same export. A short-lived materialized export
  is sufficient; no general artifact-versioning or edition system is required.
  Specify expiry, retry behavior, cursor parameter binding, and what happens
  after a server restart. An expired cursor must fail explicitly rather than
  silently restarting against different data.
- Scope control: storage of an export is a technical cache, not an editorial
  write tool. If a weaker live-read contract is deliberately chosen instead,
  remove the snapshot/exactly-once claims and state the limitations plainly.
- Guardrails: paginate while re-extracting an included article, changing feed
  membership, and inserting new articles; repeat a page request; resume an
  oversized article after its source extraction changes; verify index totals
  and concatenated bodies match the export. Test expiry and malformed or
  mismatched cursors.

### MCP-03: The proposed public container can reach the admin application

- Severity: High before public exposure. Type: inaccurate trust boundary.
- Plan: lines 79-82, 159-171, 183-185, and 244-246.
- Evidence: `docker-compose.prod.yml` exposes the Phoenix service on port
  4000; `newspaper/lib/newspaper_web/router.ex` serves the admin LiveViews
  through that same endpoint without user authentication. The proposal gives
  the MCP container access to `http://app:4000`.
- Problem: four read-only tool handlers do not establish that the container
  has "no route to any admin action." Code running in a compromised sidecar
  could reach the admin surface. A bearer token on the new API authenticates
  that API's requests but does not protect neighboring admin routes.
- Recommendation: distinguish read-only tool semantics from network
  isolation. Restrict the public-facing container's upstream access to the
  read API through a dedicated listener or gateway plus effective network
  restrictions. A second port or network name alone is insufficient if the
  sidecar can still reach the original admin endpoint through another path.
  Do not attach it to the headed-browser control network or supply database
  credentials.
- Scope control: this finding concerns the newly public service, not a
  request to retrofit authentication throughout the trusted-LAN application.
  Any decision to trust the sidecar like a LAN client must be explicit and
  must remove the stronger isolation claim.
- Guardrails: verify from the deployed sidecar network that required API
  calls work but admin actions, database access, and browser-control endpoints
  are unavailable. Verify the public reverse proxy exposes only the intended
  MCP and discovery routes, not Phoenix routes.

### MCP-04: Missing-content reporting has no defined selection window

- Severity: Medium. Type: contradictory coverage contract.
- Plan: lines 107, 117-120, 134-136, and 199-202.
- Problem: an article with no successful extraction has no extraction time,
  so it cannot be selected by the same extraction-time predicate. The index
  cannot report "unextracted articles in the window" until a separate cohort
  is defined. A source that has stopped fetching can otherwise look like a
  source that simply published nothing.
- Recommendation: distinguish the readable set from a coverage set. A small
  starting contract is articles first observed in the interval, filtered to
  the requested feeds, with their factual extraction states. State which
  intake or eligibility timestamp defines observation. Keep pending, failed,
  and valid no-content outcomes distinct. Expose source last-fetch time and
  status as factual metadata; leave any warning or interpretation to the
  agent prompt.
- Scope control: coverage reporting must not trigger extraction, digestion,
  or automatic recovery. An explicit unavailable/unknown value is preferable
  to inventing a completeness guarantee.
- Guardrails: newly observed pending and failed articles; valid no-content
  results; an old article extracted today; a quiet source versus a stale or
  failed source; readable-set counts remaining separate from coverage counts.

### MCP-05: Page budgets do not yet define lossless bounded responses

- Severity: Medium. Type: payload and continuation contract.
- Plan: lines 107-115, 128-133, 149-151, and 214-217.
- Problem: a single paragraph can exceed the page budget. Headers and
  serialized metadata also consume space. Character counts are not equivalent
  to client byte or token limits, and JavaScript and Elixir must agree on
  offset units. The body-free index can itself become too large for a broad
  window. Exact total page counts depend on a fixed budget and frozen text.
- Recommendation: define budget accounting, including framing, and a
  lossless fallback split within oversized paragraphs. Define Unicode-safe
  offsets and continuation identity consistently across both implementations.
  Bound or paginate the index as well as article bodies. Reject unsupported
  ranges or budgets explicitly rather than silently truncating information.
  Bind the budget to the cursor, or specify how changing it works. Omit exact
  total pages if they cannot be supplied reliably; a correct continuation
  cursor and remaining article count are sufficient for naive retrieval.
- Guardrails: one huge paragraph; non-ASCII text; long metadata; tiny and
  maximum budgets; broad windows; an empty result; reconstructing original
  text exactly from all parts. Test serialized result sizes on the selected
  client and confirm it can actually use continuation metadata, whether
  supplied as text, structured content, or both.

### MCP-06: Paging alone does not establish agent-runtime feasibility

- Severity: Medium. Type: integration claim, not a backend feature request.
- Plan: lines 34-37, 64-71, 176-178, 196-203, and 214-217.
- Problem: writing notes after each page does not remove earlier full-text
  tool results from conversation history. The proposal does not identify
  where durable notes or the previous successful cutoff live. A job limited
  to this read-only connector cannot assume an additional notes-writing tool.
  The stated 200k-context guarantee and subscription-cost assumptions are not
  established by pagination alone.
- Recommendation: choose one actual consuming environment for the first
  integration check. Verify scheduled connector access, token refresh,
  result-size handling, and its real context-management behavior. Use its
  existing runtime facilities for compaction, isolated page processing, or
  durable notes if available; do not implement those facilities in News.
  Describe measured client limits rather than universal pricing or context
  guarantees.
- Recovery boundary: the consuming agent/runtime owns its delivery
  checkpoint. Advance it only after completing the intended run; a failed or
  partial read must not silently become a successful day's checkpoint. The
  server supplies deterministic export/cursor behavior, not a scheduler.
- Guardrails: retrieve a heavy weekday end to end, compare GUIDs and complete
  text against the export, interrupt and resume, handle export expiry and
  token refresh, and label incomplete retrieval explicitly. Writing a good
  brief remains a prompt concern, not an additional MCP implementation gate.

## Remaining Auditor Questions

### Auth0 audience selection

Investigate the existing tenant before creating a second one. Auth0 documents
a **Resource Parameter Compatibility Profile** that lets the OAuth `resource`
parameter select the registered API audience:

- [Auth0: MCP Audience Error](https://support.auth0.com/center/s/article/mcp-audience-error-with-auth0)
- [Auth0: Authorize with PKCE](https://auth0.com/docs/api/authentication/authorization-code-flow-with-pkce/authorize-with-pkce)

This is a supported configuration path to test, not confirmation that the live
tenant has it enabled or that every proposed client supplies the expected
parameter. Verify initial authorization and refresh with the chosen client,
reject Trilium tokens at News and News tokens at Trilium, and confirm the
existing integration still works. Do not change the tenant's default audience
blindly or accept Trilium's audience as a workaround. Keep permission to read
News limited to the intended user; possession of an arbitrary tenant login is
not the intended authorization policy.

### Copying versus sharing

Copying the small transport/auth layer is reasonable for this interim service.
Record its source revision and an explicit responsibility to propagate relevant
security fixes. Retain the applicable upstream tests. Do not extract a shared
framework merely to avoid this limited duplication, and do not copy deployed
secrets or Trilium-specific audiences, scopes, and upstream permissions.

### Retirement

Make the bridge removable without changing ingestion, extraction, RSS identity,
or the future Newspaper domain. Removal is appropriate when Ian no longer
needs external-agent retrieval, not merely when the first local edition can
be generated. Even after local synthesis exists, a thin retrieval interface
may remain useful. No expiry date or automatic removal mechanism is needed.

## Reconciliation Guardrails

- Resolve the retrieval contracts in the main proposal before implementation;
  keep implementation details proportionate to an interim export service.
- Preserve extraction/digestion independence: select from extracted content
  and requested memberships, not only published RSS items. Digest-dependent
  feeds may hold items unpublished; pausing digestion must not force changing
  RSS rendering preferences just to read those extractions through MCP.
- Do not interpret article/source row-count ratios as semantic same-story
  duplication. Return distinct article GUIDs faithfully; combining coverage
  belongs entirely to the prompt.
- Start real-client integration with one client, then expand compatibility.
  Server correctness and agent-runtime support should have separate evidence.
- Keep the main proposal's hostname and public-network changes subject to
  Ian's approval. This audit adds no authorization to expose a service.
