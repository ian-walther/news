# Test Coverage Gaps

The suite is genuinely good where it looks (see 09-strengths). These are the
places it doesn't look. Ordered by value of adding coverage, and aligned with
the bugs above so fixes can follow the repo's red-green rule (AGENTS.md #5).

---

## T-1 — RSS output (`FeedController`) has almost no direct coverage

Only one assertion renders a feed (`pipeline_ungrouped_feed_test.exs:51`).
Untested behaviors, several of which are specced:

- Disabled feed returns 404 (`workflow.md` enabled/disabled semantics).
- Unknown GUID returns 404; multi-segment paths return 404.
- Item ordering (rendered/published desc, fallback) and `item_limit`
  windowing (`rss-output-shape.md` Feed Window).
- Escaping: title/link/author escaping, and the C-3 CDATA `]]>` case (write
  this test first when fixing C-3).
- `publication_status: "processing"` items excluded from output
  (digest-waiting semantics, `rss-output-shape.md`: "publication waits").
- Content-type header of the response.

## T-2 — `FeedParser` has no unit tests at all

No test exercises RSS2/Atom fixtures. When C-1 is fixed (parser replaced or
augmented), fixture-based tests should pin: `content:encoded` vs
`description` body selection, author, categories, enclosures, `updated`,
GUID-less items, malformed dates (RFC1123 + ISO), and entity handling.
Today even the five mapped fields are only covered indirectly through
end-to-end pipeline tests.

## T-3 — Concurrency races are untested (and present)

C-4/C-5's find-then-insert races have no tests. After converting to real
upserts, add tests that call `upsert_raw_item`/`create_or_update_from_raw_item`
concurrently (`Task.async_stream` over the same items) and assert single rows
and no crashes. Same for `ensure_item_for_feed`.

## T-4 — Dispatcher failure modes are untested

Existing dispatcher tests cover recovery, pacing, priority, and retry-now —
the happy and specced paths. Untested: task death without a `{:finished}`
cast (R-1), enqueue with nil site host (R-2), and `retry_now` racing a timer
fire. These are exactly the wedge scenarios; a test double for
`Extraction.execute_attempt` that raises would cover R-1 cheaply once the
monitor fix exists.

## T-5 — Membership update semantics of `update_generated_feed`

No test pins what happens when `update_generated_feed` receives attrs without
`intake_group_ids`/`input_feed_ids` (C-10). Whatever semantics are chosen
("absent = unchanged" recommended), pin them.

## T-6 — Backfill eligibility and the 5,000-article cap

`backfill` tests cover creation and disabled-feed skip, not: articles beyond
the query cap (P-2), input-feed-level inclusion via `article_sources`, the
disabled-input-feed-in-included-group question (D-8), and one-item-per-article
when eligible through multiple rules (specced in `pipeline.md` Output Feed
Rule Model — the unique index enforces it, but no test asserts the no-crash
path through `ensure_item_for_feed`).

## T-7 — `advance_item` history preservation

No test asserts that a succeeded item step's `finished_at`/`reused_artifact`
survive later advancement passes (C-6). Add one alongside the fix: extract,
then digest, then assert the extraction step row still shows
`reused_artifact: false` and its original `finished_at`.

## T-8 — Run-record hygiene

No tests assert that every started run reaches a terminal status on failure
paths (R-3, R-5, C-4). A generic helper ("after operation X with induced
failure, no `runs` row remains `running`") would police the whole class.

## T-9 — Digest snapshot determinism across model changes

Tests cover generation, validation, and reflow. Untested: the specced
snapshot behavior that queued digestion work uses the model captured at
enqueue time even if the global setting changes before execution
(`architecture.md`: "snapshots that model … so queued work remains
deterministic"; implemented in `settings_for_attempt/1`). Also untested:
digest artifact reuse via fingerprint when re-requesting with an unchanged
model, vs regeneration when the model changed.

## T-10 — Worker JS edge cases

The 16 worker tests cover the sanitizer, rate limiting, timeout, quality
basics, and JS rendering. Missing: `parseRetryAfter` HTTP-date form, redirect
final-URL propagation, `unsupported_content_type`, the `]]>`-adjacent
"weird content survives sanitize-html" cases, and `scoreQuality`'s 70%-of-min
pass behavior (D-6 — pin it if it is intended).
