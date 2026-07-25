# Correctness Bugs

Bugs with concrete, describable failure scenarios. Ordered by severity.

---

## C-1 — Feed parsing permanently discards most raw item data

- **Severity:** critical (product correctness + irreversible data loss)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline/feed_parser.ex:23-40`, dependency `fiet ~> 0.3`

`FeedParser.map_item/2` hardcodes:

```elixir
author: nil,
feed_updated_at: nil,
categories: [],
media: %{},
```

and sets `body: item.description`, `summary: item.description`. This is not an
oversight in the mapping — the underlying parser makes the data unavailable:
`Fiet.Item` only has five fields (`id`, `title`, `description`, `published_at`,
`link`; see `deps/fiet/lib/fiet/item.ex`). Consequences:

1. **Full-content bodies are lost.** Feeds that publish full content via
   `content:encoded` (very common — Ars Technica, most WordPress feeds) get
   only the short `description` captured. The "original feed body" pass-through
   mode therefore publishes summaries where the upstream feed had full articles.
2. **Author, categories/tags, enclosures, and per-item updated timestamps are
   never captured**, even though `raw_items` has columns for all of them and
   `data-model.md` lists them explicitly ("author", "categories/tags",
   "media/enclosure metadata", "updated timestamp").
3. **The loss is permanent.** `raw_metadata` is built by `stringify(item)`,
   which serializes the same five-field Fiet struct — so there is no fuller
   snapshot to re-parse later. This violates `pipeline.md`: "The app should
   store enough raw parsed feed data … that it does not need to consult the
   original upstream feed entry after ingestion."
4. **Downstream snapshot fields are dead in practice.** `rendered_author`,
   `rendered_categories`, `rendered_media`, `rendered_updated_at` on
   `generated_feed_items` are always nil/empty; the RSS renderer's
   `<category>` and author handling never fires. The representative-selection
   fallback "earliest usable feed item `updated_at`" (`pipeline.md`
   Deduplication Boundary) can never trigger because `feed_updated_at` is
   always nil.

**Fix direction:** replace or augment the feed parser. Either switch to a
parser that surfaces the full item (author, categories, enclosures,
`content:encoded`, `updated`), or keep Fiet for structure detection and store
the raw per-item XML fragment in `raw_metadata` so richer parsing can be added
and backfilled later. Add parser unit tests for RSS2 + Atom fixtures that
assert these fields are captured (see T-2).

---

## C-2 — Cross-feed stable-ID dedupe can never match

- **Severity:** high
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:253-257` (`feed_guid_key/1`), `newspaper/lib/newspaper/content.ex:358-367`
- **Spec:** `pipeline.md` Deduplication Boundary: "Current dedupe should use normalized URL **and feed-provided stable ID** as its initial signals."

The GUID dedupe key is built as:

```elixir
"feed_guid:#{input_feed_id}:#{guid}"
```

Because the input-feed ID is embedded, the same publisher GUID appearing in
two different sub-feeds of the same intake group produces two different keys
that can never match each other. Within a single feed, duplicates are already
prevented by the `raw_items` unique index on `(input_feed_id, feed_guid)` — so
the GUID signal contributes nothing to intake-group dedupe, which is its whole
purpose ("repeated articles published to multiple feeds from the same
outlet").

**Failure scenario:** WSJ Tech and WSJ Markets both carry the same article.
The two feed entries share a stable publisher GUID but use different tracking
URLs whose difference survives URL normalization (e.g., different
`?mod=rss_...` values — `mod` is not in the stripped-params list). Result: two
canonical articles, duplicate items in every output feed that includes the
group.

**Possible justification:** scoping GUIDs per feed avoids collisions between
unrelated publishers if a group ever mixes outlets. But within an intake group
(explicitly "one outlet or one logical source family") the spec expects the
stable ID to dedupe across sub-feeds. A middle ground is scoping the key to
the intake group rather than the input feed.

Related weakness (same area): an article stores only **one** `dedupe_key`
(`content.ex:369-388`). If an article is first keyed by URL and a later
appearance matches only by GUID (or vice versa), the lookup
`get_article_by_dedupe_keys/2` can only match keys equal to the one stored
key. A dedupe-keys join table (or an array column) would let both signals
match, which is what the "extensible dedupe engine" language in the plan
implies.

---

## C-3 — RSS output: unescaped CDATA and hand-built XML

- **Severity:** high
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper_web/controllers/feed_controller.ex:40-56`

`render_item/1` emits:

```elixir
<description><![CDATA[#{item.rendered_body || item.rendered_summary || ""}]]></description>
```

If a rendered body contains the byte sequence `]]>` — entirely possible in
upstream feed HTML (e.g., a code sample or a nested CDATA remnant) or in
extracted article HTML — the CDATA section terminates early and the rest of
the document is invalid XML. FreshRSS will then fail to parse the **entire
feed**, not just the one item.

The standard fix is to split the sequence when embedding
(`String.replace(body, "]]>", "]]]]><![CDATA[>")`) or to escape the body
instead of using CDATA. More broadly, the whole document is assembled by
string interpolation; a small XML builder (or at least a dedicated,
well-tested escaping module with tests for the `]]>` case) would be safer.

---

## C-4 — One bad raw item crashes the whole feed fetch and strands the run

- **Severity:** high
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:41-45`; `newspaper/lib/newspaper/intake.ex:137-154`

```elixir
raw_items =
  Enum.map(parsed_feed.items, fn item ->
    {:ok, raw_item} = Intake.upsert_raw_item(feed, item)
    raw_item
  end)
```

`upsert_raw_item/2` can fail in several real ways:

- `find_raw_item` is a **find-then-insert with no upsert semantics**. Two
  concurrent fetches of the same feed (manual per-feed fetch from the Intake
  page runs in an unsupervised task, `intake.ex:181-191` / `admin_live/intake.ex:181`,
  and can overlap the scheduled global fetch, which only guards against
  *global* overlap) race to insert the same item. The loser hits the unique
  index `(input_feed_id, feed_guid)` — and because the changeset declares no
  `unique_constraint` for it, this raises `Ecto.ConstraintError` rather than
  returning `{:error, changeset}`.
- An item stored earlier without a GUID under URL X, later republished with a
  GUID and the same URL, is not found by the GUID-first lookup and the insert
  violates the `(input_feed_id, url)` unique index.
- Any changeset validation failure returns `{:error, changeset}`, and the
  `{:ok, raw_item} =` match raises `MatchError`.

In every case the fetch task crashes mid-run: the `fetch_input_feed` run row
stays `running` forever (nothing recovers interrupted fetch runs on restart —
recovery only exists for pipeline attempts and batches), no failure record is
created, and the remaining items of that feed are skipped. `workflow.md` calls
for "prefer observable failures over silent omissions" — this failure is
silent except for a crash log.

**Fix direction:** make `upsert_raw_item` a real upsert
(`on_conflict`/`conflict_target`, both indexes considered), and make the fetch
loop tolerate a per-item error by recording a failure and continuing. Also see
R-5 (stranded `running` runs generally).

---

## C-5 — `process_intake_group`/`Content.create_or_update_from_raw_item` has the same crash-on-race shape

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/content.ex:369-388`, `newspaper/lib/newspaper/publishing.ex:152-161, 190-219`

`create_or_update_from_raw_item` does get-then-`Repo.insert!`; concurrent
processing of the same intake group (scheduled fetch of feed A and manual
fetch of feed B in one group both call `process_intake_group`) can race two
inserts of the same article; the loser raises on the
`(dedupe_scope, dedupe_key)` unique index. Similarly
`Publishing.ensure_item_for_feed` does `Repo.get_by` then insert, and
`create_item_if_missing` pattern-matches only `{:created, _}/{:existing, _}` —
an `{:error, changeset}` return from `create_item!` (e.g., from
`Processing.enqueue_item` failing inside the `with`) raises `MatchError` and
takes down the enclosing fetch/processing run.

**Fix direction:** upsert with `on_conflict` + re-select, or serialize
processing per intake group; make the publish loop error-tolerant per feed.

---

## C-6 — `advance_item` rewrites completed step history on every pass

- **Severity:** medium (data fidelity, operator-facing history)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/processing.ex:360-382` (`advance_item_step/3`), `processing.ex:1214-1221` (`success_state/1`)

`advance_item_step` sends any item step whose status is `succeeded` (also
`pending`/`blocked`) through the "reusable artifact" path:

```elixir
{:ok, artifact_attrs} ->
  item_step = update_item_step!(item_step, Map.merge(artifact_attrs, success_state(true)))
```

`success_state(true)` sets `reused_artifact: true` and
`finished_at: DateTime.utc_now(:second)`. `advance_item` runs over **all** of
an item's steps every time anything advances — e.g., after digestion succeeds,
`attach_artifact → advance_article_items → advance_item` re-walks the item and
rewrites the already-succeeded **extraction** step row: its `finished_at` is
reset to "now" and `reused_artifact` is forced to `true` even though the step
originally produced the artifact itself.

**Spec:** `data-model.md` (`generated_feed_item_steps`) requires a
"reused-artifact flag" and execution timestamps precisely so the item's
history distinguishes fresh work from reuse; `pipeline.md`: "Attempt records
explain how those results were produced." This bug systematically corrupts
both signals for any article that goes through more than one advancement pass
(i.e., nearly every article on a feed with extraction + digestion).

**Fix direction:** in `advance_item_step`, treat `status: "succeeded"` as a
plain `{:continue, item_step}` without rewriting, and only apply
`success_state/1` when the status transitions from a non-terminal state.

---

## C-7 — Representative re-election reverts extraction-corrected article metadata

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/content.ex:717-753` (`article_attrs/3`, `maybe_update_representative/2`) vs `content.ex:537-594` (`record_extraction_success/4`)

`record_extraction_success` overwrites `article.title`, `article.author`, and
`article.resolved_url` with extracted values. Later, if a raw item with an
*earlier* timestamp arrives (or history is reprocessed after an older feed
entry appears), `maybe_update_representative` rebuilds the article from
`article_attrs(raw_item, …)` — which resets `title`, `author`,
`resolved_url` (and `canonical_url`) back to raw feed values while
`extraction_status` stays `succeeded`. The extraction artifact keeps the
better values, but the article row silently loses them, and anything rendered
from article fields (article admin list, hosted page fallbacks) regresses.

Two separate design smells combine here:

1. Extraction mutating the canonical article's `title`/`author` at all —
   the plan keeps extraction output in the artifact
   (`article_extractions`), with articles holding feed-derived identity. If
   overwriting was intentional ("metadata corrected"), it needs to survive
   representative changes.
2. `article_attrs` being reused wholesale for representative updates instead
   of updating only representative-derived fields.

---

## C-8 — Dashboard article counts omit `skipped`, so numbers don't add up

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/content.ex:79-95` (`article_status_counts/0`)

The returned map has `total` (includes skipped articles) but no `skipped`
bucket; the dashboard's four tiles (`admin_live/dashboard.ex` "Article
health") therefore undercount: `extracted + failed + queued + running +
not_requested < total` once any article is skipped (no-content), which the
no-content classification migration (`20260719205207`) makes common. Either
add a skipped tile or fold skipped into an existing bucket deliberately.

---

## C-9 — `docker-compose.prod.yml` breaks if `PORT` is changed

- **Severity:** low
- **Confidence:** certain
- **Location:** `docker-compose.prod.yml` (app service)

```yaml
environment:
  PORT: ${PORT:-4000}
ports:
  - "${PORT:-4000}:4000"
```

The container listens on `$PORT` (runtime.exs reads it) but the port mapping
always targets container port 4000. Setting `PORT=5000` in `.env.prod` maps
host 5000 → container 4000 where nothing listens. Pin the container side to
the same variable or hardcode both sides.

---

## C-10 — `update_generated_feed` silently wipes memberships when IDs are absent

- **Severity:** medium (latent — no current caller triggers it)
- **Confidence:** certain (code path), possible (real-world trigger today)
- **Location:** `newspaper/lib/newspaper/publishing.ex:48-55, 395-408` (`put_memberships/2`)

Every call to `create_generated_feed`/`update_generated_feed` runs
`put_memberships`, which reads `intake_group_ids`/`input_feed_ids` from attrs
and `put_assoc`s the result — defaulting to `[]` when the keys are missing.
Any update that doesn't include both keys **deletes all membership rows**
(`on_replace: :delete`).

Today the only caller is the output-feed settings form, which always renders
both multi-selects, so the destructive path is not normally reachable — but
note that an HTML multi-select with zero selections submits *no* key, which is
indistinguishable from "caller didn't pass memberships". The first future
caller that updates any other field (say, a list-page enable/disable toggle,
which the UI currently lacks — see N-9) will silently clear feed membership.

**Fix direction:** only touch associations when the keys are explicitly
present (and use hidden empty-array inputs in the form to make "deselect all"
explicit), or split membership updates into a dedicated function.
