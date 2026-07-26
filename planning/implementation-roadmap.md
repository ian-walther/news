# Implementation Roadmap

## Expansion Strategy

Build the personalized Newspaper as a sequence of durable domain capabilities
over the existing Reading Feed. Do not create a parallel ingestion stack or
make Newspaper sources join fake Output Feeds.

Each phase should land with migrations, UI, operator visibility, tests, and
planning updates. Preserve current Article, Output Feed, generated feed item,
and RSS GUID identities throughout the transition.

## Phase 1: Outlet and Appearance Migration

Replace the generic Intake Group vocabulary with the required Outlet domain
concept.

Implementation targets:

- Rename `IntakeGroup` and `intake_groups` to `Outlet` and `outlets`.
- Make every Input Feed belong to one Outlet.
- Create one Outlet for each currently ungrouped Input Feed, with explicit
  operator review available for later consolidation.
- Move Outlet strings and dedupe configuration to the relationship-backed
  model while preserving historical snapshots where needed.
- Rename `ArticleSource` and `article_sources` to `ArticleAppearance` and
  `article_appearances`.
- Rename generated-feed membership from Intake Groups to Outlets.
- Update routes, forms, labels, associations, run names, filters, and tests.
- Preserve every Raw Item, Article, dedupe key, extraction, digest, pipeline
  attempt, generated feed item, rendered snapshot, and stable identifier.

Acceptance criteria:

- All existing Reading Feeds render the same stable item GUIDs.
- Every Input Feed has exactly one Outlet.
- Repeated appearances across one Outlet deduplicate as before.
- Output Feeds can include whole Outlets or individual Input Feeds.
- The operator UI no longer presents Intake Group as a separate concept.

## Phase 2: Shared Upstream Enrichment

Move extraction and app-owned Article classification upstream of outputs.

Implementation targets:

- Add Outlet/Input Feed enrichment policy and inheritance.
- Schedule one reusable Article Extraction independent of Output Feed
  membership.
- Preserve compatibility with existing output-scoped extraction attempts and
  artifact references.
- Add versioned Article Classification artifacts for sections, Topics,
  politics, entities, and geographic relevance.
- Treat feed categories and sub-feed membership as hints.
- Add explicit backfill actions for existing Articles.
- Advance waiting Output Feed or Newspaper work when a shared artifact becomes
  available.

Acceptance criteria:

- A Newspaper-only Input Feed can fetch, extract, and classify Articles.
- Several consumers reuse the same extraction/classification artifact.
- Enabling enrichment is future-only unless the operator requests backfill.
- Failures remain visible and retryable through the existing Processing model.

## Phase 3: Newspaper Configuration and Taxonomy

Add the configurable policy surface required before Event admission.

Implementation targets:

- Add one initial Newspaper configuration with timezone, cutoff, deadline, and
  delivery settings.
- Add stable configurable Section and Tag records with the initial controlled
  vocabulary.
- Add locality profiles and geographic relationships.
- Add independent Outlet participation, base weights, Input Feed overrides,
  Topic overrides, and Local/locality overrides.
- Use absolute effective weights and show inheritance in the UI.
- Keep Output Feed memberships independent from Newspaper policy.

Acceptance criteria:

- Each new Outlet defaults to weight `1.0`.
- The UI explains the effective value and most-specific applicable rule.
- A Local-only Newspaper policy does not remove nonlocal Articles from Reading
  Feeds.
- Taxonomy labels, visibility, and order can change without code edits.

## Phase 4: Event Clustering and Admission

Create cross-Outlet Events without weakening Outlet-scoped Article identity.

Implementation targets:

- Generate candidate clusters using metadata, normalized text, named entities,
  information-retrieval signals, and later embeddings where justified.
- Persist clustering evidence and implementation versions.
- Detect exact syndication and represent likely reporting dependencies or
  common origins.
- Calculate coverage breadth, weighted prominence, and evidentiary
  independence separately.
- Implement normal, Local singleton, and primary-evidence admission paths.
- Add explicit reversible Event merge, split, attach, and detach actions.
- Add minimal Active/Dormant Story Threads and automatic reactivation.

Acceptance criteria:

- Normal admission requires at least two eligible Outlets and combined
  effective weight `>= 2.0`.
- Widespread lower-weight coverage can qualify without being presented as
  independent corroboration.
- A Local singleton and a directly establishing primary document can use their
  distinct admission paths.
- A denial establishes the denial, not the denied Claim.
- Operators can inspect why an Event qualified or failed.

## Phase 5: Claims, Evidence, and Synthesis

Implement the editorial substrate before generating publishable prose.

Implementation targets:

- Finalize the minimal Claim type, evidence relationship, source role,
  independence, origin, and interested-party vocabulary.
- Extract Claims and source locations from admitted Event Articles.
- Preserve contradictions, uncertainty, and dependency chains.
- Synthesize neutral headline, compact summary, and paragraph-form article.
- Generate optional Story So Far content from prior Story Thread Events.
- Create numbered Claim-level Citations and validate every material unique
  Claim before marking a story complete.
- Persist model, prompt, schema, input, and implementation versions.

Acceptance criteria:

- The output does not summarize one privileged Article.
- Material unique Claims have traceable citations.
- Unsupported or invalid prose cannot become a completed Edition Story.
- Interested-party statements remain properly scoped and attributed.
- The prose distinguishes broad repetition from independent evidence.

## Phase 6: Deterministic Hosted Editions and Delivery

Add scheduled immutable publication.

Implementation targets:

- Freeze eligible Article and configuration revisions at content cutoff.
- Persist a sealed generation manifest.
- Record phase timing, queue depth, story counts, failures, and deadline
  margin.
- At the hard deadline, seal every complete valid Edition Story.
- Publish a tablet-friendly hosted Edition and archive route.
- Send a lightweight email containing the date, section/headline overview, and
  Edition link.
- Record delivery attempts independently from generation.
- Send a failure notification when zero valid stories complete.

Acceptance criteria:

- One valid story can publish a thin Edition.
- Incomplete work never appears in the Edition.
- Late work cannot mutate the sealed artifact.
- Retrying against one manifest is deterministic and inspectable.
- Delivery retries do not regenerate the Edition.
- Old Edition URLs and contents remain stable.

## Phase 7: Corrections and Operational Refinement

Implementation targets:

- Add correction, clarification, and retraction records.
- Publish them in a later Corrections section linked to the affected Edition
  Story and Claim.
- Add post-publication operator workflows without editing the original
  artifact.
- Tune clustering, classification, source dependency detection, Local rules,
  processing concurrency, and schedule recommendations from observed results.
- Add retention protection for every artifact referenced by an Edition or
  Citation.

## Deferred Expansion

Defer until the hosted RSS/Atom Newspaper is reliable:

- Twitter-specific and newsletter ingestion
- automatic discovery of official sources
- supplemental Editions
- PDF and print rendering
- Home Assistant and MQTT controls
- automatic source-reputation suggestions
- public Internet exposure and its required security architecture
