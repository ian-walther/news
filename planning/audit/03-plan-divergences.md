# Plan Divergences

Places where the implementation observably strays from the planning docs.
Some may be deliberate decisions from implementation chats; each entry notes a
possible justification where one is imaginable. Cross-references: C-1
(raw-capture data loss) and C-2 (stable-ID dedupe) are also divergences but
live in the bugs file because they have concrete failure modes.

---

## D-1 — Ungrouped input feeds exist; the plan has no such concept

- **Severity:** medium (conceptual drift)
- **Confidence:** certain (code); unknown (intent)
- **Location:** migration `20260609001934_allow_ungrouped_input_feeds.exs`; `articles.dedupe_scope` (`"group:N"` / `"feed:N"`); `pipeline.ex:306-312` (`process_feed_boundary/2`); `intake.ex:63-68`
- **Spec:** `pipeline.md` Vocabulary and Pipeline Shape route every input feed through an intake group; `data-model.md` `sources` lists a required intake group ID.

The implementation allows input feeds with no intake group, adds a
`dedupe_scope` mechanism to support per-feed dedupe, a `process_input_feed`
run type not in the planned run-type list, and a dedicated test file
(`pipeline_ungrouped_feed_test.exs`). None of the planning docs mention
ungrouped feeds. There is even a deliberate migration relaxing the original
NOT NULL schema, so this was a considered change — but the planning docs were
never updated (violating AGENTS.md rule 2: keep docs in sync).

**Action:** either document the concept in `pipeline.md`/`data-model.md`
(vocabulary, dedupe scope semantics, run types) or remove it. If kept, the
dedupe-scope design deserves a sentence in the dedupe boundary section since
it changes the dedupe unit.

---

## D-2 — Fetch does not honor per-feed pacing/politeness or conditional requests

- **Severity:** low (today), medium (as feed count grows)
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:31-68`

`fetch_input_feed` issues a plain `Req.get` with default options: no
`If-Modified-Since`/`If-None-Match`, no timeout tuning, no per-host spacing,
and a default Req user agent. The plan doesn't spec conditional fetches
explicitly, but `sources` in `data-model.md` includes "fetch cadence" and
"last fetch status" — cadence is global-only today (which `workflow.md` allows:
"Per-feed schedules remain deferred"), and unconditional refetching of every
feed every 5 minutes is the kind of upstream-unfriendly behavior the
site-policy work carefully avoids for articles. Cheap wins: send
`If-None-Match`/`If-Modified-Since` from stored values, set an explicit user
agent, and treat 304 as success.

---

## D-3 — `<author>` / categories / enclosures never reach the RSS output

- **Severity:** medium
- **Confidence:** certain
- **Location:** consequence of C-1; renderer at `feed_controller.ex:40-56`
- **Spec:** `rss-output-shape.md` Render Snapshots lists author/byline, categories/tags, media/enclosure among snapshot fields to render.

Even after C-1 is fixed, note the renderer has no enclosure output at all
(`rendered_media` is never rendered), and `<author>` uses the byline text
(RSS 2.0 `<author>` is specified as an email address; `<dc:creator>` is the
conventional element for names — FreshRSS handles `dc:creator` well).

---

## D-4 — Digestion prompt/validation constants vs plan's pilot posture

- **Severity:** informational
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/digestion.ex:201-232`, `digestion/ollama_client.ex:95-186`

`next-scope.md` calls for "Prompt, length, and validation tuning driven by
actual reading quality" — implementation hardcodes 250–400 words in the prompt
but validates 80–600 words, and **rewrites** model output that doesn't have
3–5 paragraphs (`reflow_summary/1` re-chunks sentences/words evenly). Two
skeptical notes:

1. After `normalize_summary`, the "must contain 3 to 5 paragraphs" validation
   is nearly unfalsifiable — reflow guarantees 3–5 chunks — so the check only
   documents intent. Fine, but be aware the guard is cosmetic.
2. Reflowing silently reshapes model output. `rss-output-shape.md` only
   promises escaping and "predictable feed-safe paragraphs", so this is
   defensible, but it means stored `generated_summary` is not verbatim model
   output while `article_digests` is supposed to be the auditable artifact
   (`vision.md`: "Make bad decisions auditable and correctable"). Consider
   storing the raw output in `output_metadata` for auditability.

---

## D-5 — `retryable: true` on all digestion failures, before failure classification was done

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/digestion.ex:149-179`
- **Spec:** `implementation-roadmap.md`: "Classify real connection, model, timeout, and structured-output failures **before** adding automatic retries."

No automatic digestion retries exist (good — matches plan), but every failure
is recorded `retryable: true` with kind `digestion_failed`/`execution_error`,
including deterministic ones (schema-validation failures, "No Ollama model is
configured"). Since `failures.retryable` drives the operator "Retry" button,
deterministically-failing work is presented as retryable, and the
`failure_kind` taxonomy the roadmap wants ("connection / model / timeout /
structured-output") is collapsed to one bucket. Cheap fix: pass through a
distinct kind per error source (the OllamaClient error strings already
distinguish them).

---

## D-6 — Extraction quality thresholds behave differently than the UI label implies

- **Severity:** low
- **Confidence:** certain
- **Location:** `workers/extraction-core/src/article.mjs:372-405` (`scoreQuality`), site policy field `minimum_text_length`
- **Spec:** `data-model.md` site policy: "minimum acceptable text length".

`minimum_text_length` is not a hard floor. Score for short content is
`max(0.1, len/min/2)` and the no-content cutoff is `score < 0.35`, so any
article ≥ 70% of the configured minimum passes as `ok`. That is arguably in
the spirit of "legitimate short prose … remain article content"
(`pipeline.md`), but the operator-facing field name ("Minimum text length")
and the plan's "minimum acceptable text length" suggest a floor. Either
document the 70% behavior or make the threshold literal and use the fuzzy
score only for diagnostics.

---

## D-7 — Escalation-worthy failure kinds `paywall`, `auth_required`, `javascript_required` are never produced

- **Severity:** informational (planned work, but the wiring invites confusion)
- **Confidence:** certain
- **Location:** `workers/extraction-core/src/article.mjs` (`classifyHttpFailure`, `classifyError`), `newspaper/lib/newspaper/extraction.ex:131-151`
- **Spec:** `features/006-browser-extraction-and-escalation.md` escalation conditions; `implementation-roadmap.md` quality classification.

The app escalates on `javascript_required` / `auth_required` / `paywall` /
`blocked` / `no_content`, but the workers can only ever emit `blocked`
(401/403), `not_found`, `rate_limited`, `http_error`,
`unsupported_content_type`, `timeout`, `network_error`, `worker_error`, and
`no_content`. JS-shell pages escalate only via the indirect `no_content` path;
paywall/login interstitials that render enough text are stored as *successful
extractions of the interstitial*. This matches the roadmap ("improve quality
classification using observed paywalls, login pages…" is future work), but be
aware today's site-policy `last_failure_kind` and escalation learning operate
on the narrower real taxonomy, and quality review of stored extractions should
expect interstitial text.

---

## D-8 — Membership rules ignore input-feed enabled state for included groups

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/publishing.ex:363-391` (`eligible_generated_feed_ids/2`), `newspaper/lib/newspaper/pipeline.ex:267-276` (`eligible_for_feed?/2`)
- **Spec:** `pipeline.md` Output Feed Rule Model: "Including an intake group means all **enabled** input feeds currently in that intake group."

Eligibility via intake group checks only `article.intake_group_id` membership;
it never inspects which input feed carried the article or whether that feed is
enabled. In steady state disabled feeds aren't fetched, so no new articles
arrive; but **backfill** will happily pull historical articles that only ever
appeared in a now-disabled feed into an output feed, and articles from a
disabled feed still flow if the same article also arrives via an enabled
sibling (that part is fine). Decide whether backfill should honor
enabled-only, and encode it.

Also note `eligible_for_feed?` (backfill) and `eligible_generated_feed_ids`
(live publish) are two separate implementations of the same rule that can
drift; see A-6.

---

## D-9 — `runs.trigger` taxonomy drift

- **Severity:** informational
- **Confidence:** certain
- **Location:** `pipeline.ex` (fetch flows pass `"system"` for nested runs, `"manual"`/`"scheduled"` at top level), `extraction.ex`/`digestion.ex` (`"pipeline"`), `output_feed.ex` (`"settings_change"`)
- **Spec:** `workflow.md`: trigger "such as `manual`, `scheduled`, or `system`" — explicitly expected to evolve.

Two undocumented trigger values exist (`pipeline`, `settings_change`), and the
Operations "overview" scope filter special-cases them
(`operations.ex:187-201`: `trigger not in ["system", "pipeline"]`). Not wrong
— the plan says the taxonomy will change — but it changed without the doc
following (AGENTS.md rule 2), and the filter logic depending on string
membership is easy to break when the next trigger value is added.

---

## D-10 — Headed-browser tier absent from the registry (known), but data can still point at it

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/processing/registry.ex` (`@extraction_order` includes `extraction.headed_browser`; `@extractors` does not), `content.ex:823-830` (`validate_policy_implementation/1`)

Headed extraction is planned-not-built (per `next-scope.md`), and the policy
form validates against the registry, so the UI can't select it. But nothing
prevents DB rows (import, manual SQL, or a future partial implementation) from
holding `minimum_implementation: "extraction.headed_browser"`;
`extraction_candidates/1` then returns `[]` and every attempt fails with
`:no_available_implementation` as a generic `execution_error` (retryable,
opaque). A clearer guard: treat unknown/unavailable minimums as "highest
available" with a visible warning, or emit a dedicated failure kind.

---

## D-11 — AGENTS.md style rules vs the actual UI stack

- **Severity:** informational
- **Confidence:** certain
- **Location:** `AGENTS.md` ("**Always** manually write your own tailwind-based components instead of using daisyUI"), `newspaper/assets/vendor/daisyui.js`, ubiquitous `btn`/`badge`/`join`/`progress` classes

The repo instructions forbid daisyUI; the app is built on it (vendored plugin
plus daisy component classes throughout every LiveView). One of the two should
change — most cheaply, the AGENTS.md line, since the UI is consistent and
works. Flagged only because conflicting standing instructions degrade future
agent output.
