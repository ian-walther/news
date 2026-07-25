# Dead Code and Schema Cruft

Things that exist but do nothing, or duplicate other things. Individually
harmless; collectively they mislead readers (and implementation agents) about
what the system actually does. For each: remove it, wire it up, or mark it
explicitly as reserved-for-future in the schema/docs.

---

## X-1 — `app_settings.run_history_enabled` is editable but never read

- **Confidence:** certain
- **Location:** `operations/app_settings.ex`, Settings UI (`admin_live/settings.ex:84-88`); zero readers (`grep run_history_enabled` finds only schema + form)

The Settings page offers "Run history/debug logging" as a toggle; `start_run`
and friends never consult it. An operator turning it off reasonably believes
run records stop accumulating. Wire it into `Operations.start_run/4` (the plan
allows "Run logging can become configurable or disabled later") or remove the
control until it does something.

---

## X-2 — Legacy v1 extraction columns on `articles` duplicate the artifact table

- **Confidence:** certain
- **Location:** `articles.extracted_content`, `articles.extraction_metadata` (migration `20260607201027`), written in `content.ex:570-577, 618-659`; read only as a fallback in `publishing.ex:348-361` (`extracted_html/1` second clause)

Every successful extraction stores the full content HTML **twice** (article
row + `article_extractions.content_html`). The only reader of the article copy
is a fallback clause that can never fire for rows written after the artifact
table existed (success always writes both). `extraction_metadata` similarly
shadows attempt records. Migrate the fallback away, stop writing
`extracted_content`, and drop the columns (or keep `extraction_metadata` if
the article-list UI's failure-kind badges are meant to read from it — today
they do: `admin_live/articles.ex:197-205` — in which case document that it is
a denormalized cache of the latest attempt).

---

## X-3 — `input_feeds.auth_required` is UI-editable but inert

- **Confidence:** certain
- **Location:** `intake/input_feed.ex`, Intake edit form (`admin_live/intake.ex:467`); no fetch/extraction code reads it

The flag matches `data-model.md` ("auth requirement flag") but nothing
consults it — fetching doesn't skip/annotate authed feeds and extraction
policy doesn't see it. Presumably it becomes meaningful with the headed
browser tier; until then it silently does nothing. Add a tooltip/note or defer
the field.

---

## X-4 — Speculative config fields with no behavior

- **Confidence:** certain
- `generated_feeds.policy_config` — cast, never read (`publishing/generated_feed.ex`).
- `intake_groups.dedupe_config` — cast, never read; dedupe behavior is
  hardcoded (`pipeline.ex:216-262`).
- `input_feeds.default_metadata` — cast, never read.
- `generated_feed_items.selection_metadata` — written as `%{"mode" => body_mode}`
  (duplicating `body_mode` column), never read.

All appear in `data-model.md` as future hooks, so keeping the columns is
defensible — but they should not be `cast` in changesets until used (silent
acceptance of junk input), per the principle in AGENTS.md of not casting
programmatic fields.

---

## X-5 — Dead public functions

- **Confidence:** certain
- `Newspaper.Pipeline.publish_output_feed/2` — alias for
  `backfill_output_feed/2`, no callers. Its existence blurs the carefully
  specced backfill-vs-publish vocabulary (`workflow.md` Manual Actions);
  remove.
- `Newspaper.Processing.enqueue_feed/2` — no callers (batches use
  `start_feed_batch`/`resume_feed_batch`; item creation uses `enqueue_item`).
- `Newspaper.Processing.enqueue/4` — no callers found outside tests.
- `Newspaper.Intake.list_ungrouped_input_feeds/0` — no callers found.
- `Newspaper.Processing.extraction_eligible_article_ids/1` — thin wrapper; the
  generic `step_eligible_article_ids/2` is what the UI calls.

---

## X-6 — Registry extractor `default_config`/`config_schema` are vestigial

- **Confidence:** certain
- **Location:** `processing/registry.ex` (`@extractors` entries)

Since migration `20260716142942` moved timeout/minimum-text-length onto site
policies, extractor-level config schemas are never used
(`normalize_step_config/2` only consults `@step_implementations`). The
duplicated min/max bounds now live in two places (registry schema and
`SiteExtractionPolicy.changeset`), which will drift. Delete the extractor
config schemas or route the policy changeset validation through them.

---

## X-7 — `Newspaper.Events` `event` atom is nearly unused information

- **Confidence:** certain
- **Location:** `events.ex`; all subscribers

Broadcasts carry a specific atom (`:intake_changed`, `:publishing_changed`,
`:processing_changed`, `:operations_changed`, `:settings_changed`,
`:site_extraction_policies_changed`) but every subscriber except the Settings
LiveView and the Scheduler matches `_event` and reloads everything. Either use
the granularity (see P-1) or stop pretending to have it.

---

## X-8 — Duplicated helper implementations across LiveViews

- **Confidence:** certain

`article_host/url_host` (dashboard, articles, operations, format),
`to_id/parse_id/parse_optional_id` (four variants), `status_badge_class`
(three variants), `blank?/present?` — each re-implemented per module with
slightly different nil/edge handling. Consolidate into `Format`/one helpers
module; the variants are how inconsistencies (e.g., `String.to_integer` vs
guarded `Integer.parse`) creep into event handlers that take user-controlled
IDs (`String.to_integer` raises on junk params — currently crashes the
LiveView process on a hand-edited DOM, harmless but sloppy).
