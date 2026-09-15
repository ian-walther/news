# Fable Review Notes — Newspaper V2 Planning

## Purpose and Protocol

This is the living working ledger for the second-opinion review of the V2
planning set (`planning/`, `planning/newspaper/`, and the Trilium snapshot).
It exists to converge Ian, Sol, and Fable on a complete plan before
implementation planning begins.

- Items are **questions and gaps**, not findings against code. IDs (`Q-1` …)
  are stable; do not renumber.
- Lifecycle: `open` → `in discussion` → `resolved`. A resolved item records
  its outcome in one short paragraph plus a pointer to where the durable
  decision landed (decision ledger, product contract, roadmap, etc.). Once the
  durable docs carry the decision, the resolved entry may be compressed to one
  line; delete nothing until then.
- Anyone (Ian, Sol, Fable) may append discussion outcomes, but dispositions
  are Ian's product calls.
- Scope: high-level product/concept robustness. Implementation detail belongs
  in the phase planning when we get there.

Review basis: full read of the reconciled planning docs, both planning
commits (`cb5a259`, `2f6ddb9`), and the complete 10-note Trilium hierarchy
(verified complete and current against live Trilium on 2026-07-26).

---

## Q-1 — Evaluation strategy for the generative core — `in discussion`

**Question.** The plan specifies what synthesis must do (claim-level
citations, attribution, uncertainty) but not how quality is measured or what
"citation validation" concretely is. A model grading a model is not a
strategy. Related gaps: no grounding-failure/hallucination detection concept;
no prompt-injection posture (article text is adversarial input to the system
that writes the trusted output).

**Progress (2026-07-26).** Partially answered by the Q-2 outcome: the
structured per-article **brief** anchors claims to source spans, which makes a
large share of citation validation *mechanical* (a cited span either exists in
the referenced extraction revision or it does not). Remaining to define: the
golden-set concept (hand-checked expected outputs for real events), the
entailment check for claims that paraphrase rather than quote, a lightweight
recurring editorial QA ritual, and a one-line data-not-instructions rule for
synthesis prompts.

**Remaining.** Subsumed into the trust-ladder question (Q-15) for the gating
structure; the concrete validation mechanics stay here.

## Q-2 — Compute feasibility and model sourcing — `in discussion`

**Question.** No doc estimated corpus scale, extraction throughput within the
cutoff→deadline window, or token/GPU budget. Underlying product decision:
local-only models as a matter of principle, or cloud escape hatch?

**Direction agreed (2026-07-26).** Three compute tiers:

- **Tier 0 — conventional, N150, continuous:** normalization, TF-IDF/n-grams,
  cosine similarity, near-dup/simhash, entity overlap, full-text search,
  admission arithmetic, orchestration. Embeddings-vs-TF-IDF is a non-question:
  compute both (embeddings on the 4090 are nearly free); thresholds are what
  shadow mode tunes.
- **Tier 1 — small/fast model, 4090, per-article, amortized 24/7:** the
  **structured brief** — a machine-facing artifact per extracted article:
  who/what/when/where, discrete claims anchored to source spans, quotes,
  numbers, entities, article type, section/geo candidates. Classification
  runs conventional-first with LLM-as-fallback for low-confidence cases.
- **Tier 2 — large model, 4090, per-event, morning window:** cluster
  confirmation, synthesis, Story So Far, validation — only for admitted
  events, consuming briefs plus selected passages (~8–15k tokens/story), not
  raw article text.

Napkin budget: 10–20 stories × 2–5 min ≈ 30–75 min on a 27–32B-class local
model — the ~1 h window holds **only** with Tier 1 in place. The budget
constraint therefore *requires* the brief design; record it as an
architectural conclusion, not an optimization.

The brief resolves the "summarize the summaries" objection: intermediate
artifacts are structured and span-anchored, so reduction loses information
visibly and preserves provenance, unlike chained prose summarization.

**New ledger candidates surfaced:**

1. Model sourcing policy: local-only via the 4090/Ollama (confirm; is a cloud
   escape hatch permanently out or merely deferred?).
2. The structured brief is a first-class versioned pipeline artifact, distinct
   from reader-facing `article_digests`, and is effectively the first
   implementation of Claim extraction (softens the Q-6 cliff).
3. The 4090 is a shared gaming PC: define contention policy (background
   briefing yields to interactive use) and the GPU-offline failure mode,
   which feeds the Q-4 edition-health gate.
4. Per-tier model classes replace V1's single global Ollama model assumption.

**Remaining.** Run the corpus census against prod (articles/day by outlet,
extracted-text length distribution, extraction success rates) to replace
planning numbers with measurements. Confirm ledger candidates with Ian.

## Q-3 — Admission semantics across time — `open`

Admission is specified per-Event, but Events span Editions. Undefined: does a
day-2 development of a previously admitted Event re-qualify via the thread's
lifetime coverage or must the new development independently clear admission?
What is an edition window's start (previous cutoff?), and does the window
expand across a failed/skipped edition or is that coverage lost?

## Q-4 — Corpus-health gate on edition generation — `open`

Nothing checks what was *missing* at cutoff. A quiet 18-hour fetch or
extraction degradation yields a confidently thin paper published on time — the
exact silent-omission failure the principles forbid, at the most visible
surface. Proposed: edition-health preconditions (fetch success, extraction and
brief completeness over the window) below which the edition publishes with a
visible degraded-coverage notice or fails loudly; the delivery email states
it. Includes the GPU-offline case from Q-2.

## Q-5 — Asymmetric error preference principle — `open`

State once in guiding principles and let it propagate: prefer over-splitting
clusters to over-merging (a merged cluster becomes one confidently-cited false
story; a split cluster is merely redundant); prefer omission to fabrication;
synthesis refuses rather than stretches. Shapes clustering thresholds,
synthesis prompts, and validation gates.

## Q-6 — Claim-level citations as v1 publication gate — `in discussion`

As written, no Edition can exist until full claim-level citation machinery
works — the entire product gated behind the least-certain component. Proposed:
an explicit **fidelity ladder** (see Q-15) where early published editions may
cite at paragraph/article-attribution level while the claim model runs in
shadow, promoting to claim-level gating on evidence. Alternative — hold the
line, full claim-level or nothing — is legitimate but must be chosen
deliberately. The Q-2 brief artifact softens this: span-anchored claims arrive
early (Tier 1), so the ladder is shorter than it looked.

## Q-7 — Reading Feed ↔ Newspaper overlap — `open`

Same event read in Reeder at 8am and in the Edition at 7pm. Probably fine by
design (different modes) but undecided. Decide: overlap is acceptable, or
Output Feeds eventually support suppressing/badging articles absorbed into an
admitted Event.

## Q-8 — Outlet-vote integrity vs syndication and ownership — `open`

Wire copy carried by an outlet's feed counts as that outlet's vote until
dependency detection matures. Common corporate ownership is not among the
dependency signals (the current seed corpus already includes Motorsport
Network siblings Autosport and Motorsport.com). Cheap adds: optional
Outlet ownership attribute as a dependency signal; acknowledge early admission
counts will be noisy — which argues for Q-9 shadow mode.

## Q-9 — Shadow-mode clustering before the policy surface — `in discussion`

Phase 3 builds the weights/taxonomy/admission UI before Phase 4 produces a
single real cluster. Real clustering behavior should inform thresholds, weight
ranges, and what explainability must show. Proposed: a thin observable-only
clustering pass (cluster + score + explain; no synthesis, no UI investment)
between Phases 2 and 3, run for weeks against real data — which also produces
the Q-1 golden set. Subsumed into Q-15 staging.

## Q-10 — "Deterministic generation" wording — `open`

LLM output is not bit-reproducible even at temperature 0. Acceptance criteria
should say *reproducible inputs, versioned transforms, inspectable retries* —
not implied identical output.

## Q-11 — Non-article edition content — `open`

A newspaper traditionally carries data furniture: weather, markets snapshot,
scores. The Edition model is 100% synthesized stories. Rule widgets in or out
explicitly (one ledger line) — it affects whether Editions are stories-only or
mixed content blocks.

## Q-12 — Naming collision — `open`

App "Newspaper," product-within-app "Newspaper." Consider a distinct name for
the edition product ("the Edition" / "the Daily") for doc and UI clarity.

## Q-13 — Reading-feed digest status — `open`

The qwen digest pilot vanished from next-scope without disposition. State in
one line that reader-facing digests remain a Reading Feed feature independent
of Newspaper synthesis (and of the Q-2 machine-facing brief).

## Q-14 — Edition permanence as a retention invariant — `open`

"Editions and everything their citations reference are permanent" should be
stated as an invariant *now*: extraction revisions become un-deletable the
moment a citation points at them, which constrains retention design from
Phase 2 onward, not Phase 7.

## Q-15 — The trust ladder (reframing of Q-1 + Q-6 + Q-9) — `in discussion`

**Question.** What are the promotion gates between "the pipeline exists" and
"I trust this paper," and what evidence promotes each stage? This is the
successor question after Q-2: staging, not specification, is what's missing.
See the current discussion in chat; outcome to be recorded here.

---

## Question Queue

Working order agreed so far: Q-2 (done pending census) → **Q-15** (active) →
Q-3/Q-4 (edition semantics and health) → Q-7/Q-8 (product overlap and vote
integrity) → remainder (mostly one-line ledger additions).
