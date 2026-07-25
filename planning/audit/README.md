# Codebase Audit — 2026-07-24

Independent audit of the Newspaper implementation against the planning docs in
`planning/`. Performed by a reviewer who was not involved in the implementation.
The full test suite (76 Elixir tests, 16 worker JS tests) passed at audit time
on commit `b83bcb7`.

## How to read this audit

Findings are grouped into files by category. Every finding has:

- **ID** — stable reference (`C-1`, `D-3`, …) for discussion and fix tracking.
- **Severity** — `critical` / `high` / `medium` / `low`.
- **Confidence** — `certain` (verified by reading the exact code paths),
  `likely` (strong code evidence, not executed), or `possible` (plausible from
  reading, may be refuted by context the auditor lacks).
- **Location** — `file:line` references into the repo at audit time.
- **Spec reference** — for divergences, the planning-doc passage being violated.

Some findings may have been deliberate decisions made in implementation chats
that never made it into the planning docs. Those are flagged with a
"possible justification" note where the auditor could imagine one. Per the
audit brief, disagreements get resolved in the audit-processing phase — the
findings below are written skeptically and assume nothing was intentional
unless a planning doc says so.

## Files

| File | Contents |
| --- | --- |
| [01-correctness-bugs.md](01-correctness-bugs.md) | Bugs with concrete failure scenarios (`C-*`) |
| [02-robustness-and-failure-handling.md](02-robustness-and-failure-handling.md) | Crash/wedge/stuck-state risks (`R-*`) |
| [03-plan-divergences.md](03-plan-divergences.md) | Where the implementation strays from `planning/` (`D-*`) |
| [04-architecture-concerns.md](04-architecture-concerns.md) | Structural problems worth fixing before the next chapter (`A-*`) |
| [05-performance-and-scalability.md](05-performance-and-scalability.md) | Unbounded work, N+1s, re-render storms (`P-*`) |
| [06-dead-code-and-schema-cruft.md](06-dead-code-and-schema-cruft.md) | Inert settings, unused fields, legacy duplication (`X-*`) |
| [07-test-coverage-gaps.md](07-test-coverage-gaps.md) | What the (otherwise good) test suite does not cover (`T-*`) |
| [08-minor-issues.md](08-minor-issues.md) | Nitpicks and small spec-compliance notes (`N-*`) |
| [09-strengths.md](09-strengths.md) | What is genuinely good and should NOT be "fixed" |

## Top findings (fix-first shortlist)

If the fix budget is limited, these give the most value, in rough order:

1. **C-1 — Feed parsing permanently discards most raw item data.** The chosen
   parser (Fiet) only exposes five fields; author, categories, enclosures,
   `content:encoded` full bodies, and updated timestamps are silently dropped
   at capture time and cannot be backfilled, because the "raw metadata"
   snapshot is built from the same five fields. This quietly violates the
   eager-durable-intake foundation the whole plan rests on, and it degrades
   the published feeds today (`description`-only bodies, no categories).
2. **C-2 — Cross-feed stable-ID dedupe never fires.** The `feed_guid` dedupe
   key embeds the input-feed ID, so the same publisher GUID appearing in two
   sub-feeds of one intake group produces different keys. Only normalized-URL
   matching actually dedupes across feeds — half of the specced dedupe signal
   is dead code.
3. **R-1 / R-2 — The extraction/digestion dispatchers can wedge permanently.**
   A single unexpected exception in the execution task (for example, the
   attempt row being deleted between enqueue and execution) permanently stalls
   that site's queue (extraction) or the entire digestion queue until restart,
   with no visibility.
4. **C-4 — One bad raw item crashes the whole feed fetch** and leaves the run
   record stuck `running` forever, with no failure record — the exact "silent
   omission" failure mode the plan says to avoid.
5. **C-3 — RSS output builds XML by string interpolation with an unescaped
   CDATA body.** Any article body containing `]]>` produces invalid XML for
   the whole feed.
6. **A-1 — Every fetch reprocesses the entire intake history.** Work per fetch
   cycle grows without bound as raw items accumulate; an intake group with N
   feeds is fully reprocessed N times per cycle.
7. **C-6 — `advance_item` rewrites completed step history** (resets
   `finished_at`, forces `reused_artifact: true`) every time it re-walks an
   item, corrupting exactly the audit trail the plan says attempts/item-steps
   exist to preserve.

## Scope and method

- Read all planning docs first (`vision`, `architecture`, `pipeline`,
  `data-model`, `workflow`, `rss-output-shape`, `prod-topology`,
  `next-scope`, `implementation-roadmap`, `open-questions`,
  `features/006-browser-extraction-and-escalation`).
- Read every non-generated Elixir file under `newspaper/lib`, all migrations,
  configs, the seed file, all three JS workers, the Dockerfile, both compose
  files, and all repo scripts.
- Read the test suite inventory and ran the full suite (`scripts/test.sh`).
- Did not run the app against live feeds; findings marked `likely`/`possible`
  were not reproduced at runtime.
