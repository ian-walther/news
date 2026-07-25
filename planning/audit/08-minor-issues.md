# Minor Issues and Nitpicks

Low-severity items. Batch these opportunistically.

---

## N-1 — RSS spec-compliance details
`feed_controller.ex`:
- `<author>` should be an email per RSS 2.0; use `<dc:creator>` for names
  (needs the `xmlns:dc` namespace).
- No `atom:link rel="self"` (recommended by validators; FreshRSS tolerates).
- `<link>` points at the feed URL itself rather than a channel homepage.
- `lastBuildDate` uses `Calendar.strftime(…, "GMT")` — fine since values are
  UTC, but `pubDate` for items uses the same formatter on possibly-nil chains;
  `rfc2822(nil)` silently substitutes "now", which fabricates a publication
  date. Prefer omitting `pubDate` when unknown.

## N-2 — URL normalization gaps in dedupe
`pipeline.ex:224-262`: strips `utm_*`, `fbclid`, `gclid` only; keeps port,
`www.` (host case only), trailing-slash handling trims only root-level
trailing slash after `to_string`. Publisher-specific params (`mod=`, `ref=`,
`smid=`, `partner=`) will defeat URL dedupe; `open-questions.md` already asks
"What URL parameters should always be stripped?" — the answer will live here.
Consider also treating scheme http/https as equivalent for dedupe keys.

## N-3 — `filter_article_search` does not escape LIKE metacharacters
`content.ex:274-292`: user search text is interpolated into an
`ilike` pattern; `%`/`_` in the search box behave as wildcards. Harmless
single-user; escape for correctness.

## N-4 — `Intake.mark_input_feed_fetched/2` broadcasts `:intake_changed` on every fetch
Every 5-minute cycle re-renders all intake-subscribed LiveViews even when
nothing changed (feeds' `last_fetched_at` did). Cheap fix alongside P-1.

## N-5 — `InputFeed.changeset` casts `last_fetch_status`/`last_fetched_at` from user attrs
Programmatic fields cast from form input (AGENTS.md Ecto guideline). Same for
`RawItem.changeset` casting `intake_group_id`/`input_feed_id` (set
programmatically in `upsert_raw_item`).

## N-6 — `Operations.get_settings/0` race can create duplicate settings rows
Find-then-insert; two concurrent callers on an empty table double-insert.
Harmless (lowest ID wins thereafter) but add a unique guard or `on_conflict`.

## N-7 — `extraction_wait_ms` second-granularity drift
`last_attempted_at` is truncated to seconds while pacing math is in ms;
worst-case pacing error ~1 s. Irrelevant at 3 s intervals; will matter if
sub-second pacing is ever configured (validation allows 0).

## N-8 — `Content.list_active_site_backoffs/0` shows stale entries
Condition `backoff_until > now or consecutive_rate_limits > 0` keeps sites
listed indefinitely after backoff expires until some other outcome resets the
counter (success or no-content). Expired-backoff-with-nonzero-counter reads as
"delayed" in the dashboard when the site is actually available.

## N-9 — Output feed list has no enable/disable affordance
`workflow.md` leans on enabled/disabled semantics; the list page
(`admin_live/output_feeds.ex`) shows the badge but toggling requires opening
the settings form and saving. Minor UX; note C-10 before adding a quick
toggle.

## N-10 — Article "Read" page requires extraction, 500s otherwise
`article_live/show.ex` raises `Ecto.NoResultsError` (→ 404) for articles
without extraction — deliberate mapping, fine — but the router has no
non-admin 404 styling and the raise-in-mount pattern will also fire for
`digests`-only articles if extraction is ever deleted while digests remain.

## N-11 — `Digestion.generate/2` `String.length/1` on 60k strings
Two full grapheme walks per article (`content_characters`,
`content_truncated`) — use `byte_size` or store both cheaply. Micro.

## N-12 — `Digestion` fingerprint includes full `content_text` but generation truncates to 60k
`input_fingerprint/2` hashes untruncated text while the model sees at most
60k chars; two extractions differing only beyond 60k produce different
fingerprints for identical model input. Harmless (over-regeneration), noted
for determinism accounting.

## N-13 — CommandWorker `exec "$2"` cannot pass arguments
`command_worker.ex` runs `exec "$2" < "$1"` — the configured extractor command
must be a bare executable path; a command with flags breaks silently. Fine for
current bin/extract scripts; document or support argv lists.

## N-14 — Compose/dev ergonomics
- `docker-compose.dev.yml` publishes Postgres on 5432 unconditionally
  (conflicts with a local Postgres; fine if none).
- Prod app container has no healthcheck; nginx has nothing to gate on during
  deploys (deploy script replaces the container and hopes).
- `.env.prod.example` ships `POSTGRES_PASSWORD=postgres` alongside the
  reminder to keep `DATABASE_URL` in sync — easy to forget one of the two;
  derive `DATABASE_URL` from the parts in the compose file instead.

## N-15 — `AdminLive.OutputFeed.assign_feed/2` double-fetch
`output_feed.ex:499-501` loads the feed then immediately reloads it by ID.
Also `handle_event("update_feed", …)` builds a changeset for validation, then
`update_generated_feed` rebuilds it — validation differences between the two
paths (`validate_rendering_dependencies` only on the first) mean the DB write
is not protected by the rendering-dependency validation if called elsewhere.

## N-16 — Failure "related" IDs stored inconsistently as ints and strings
`retry_failure_type` and `Operations.related_id/2` both defensively parse
string-or-int; producers write ints. Standardize producers and drop one
parser.

## N-17 — `runs.trigger` for automatic retries is invisible
`schedule_automatic_retry → retry_attempt` creates attempts with no marker
distinguishing operator retries from automatic rate-limit retries; the
Processing UI can't show "auto-retry 2 of 3". `pipeline.md` wants the retry
budget visible when exhausted; today the operator must count attempts by eye.
