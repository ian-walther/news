# Editorial, Evidence, and Story Model

## Editorial Objective

The Newspaper should synthesize the factual substrate across reporting while
removing avoidable partisan framing, clickbait, rhetorical heat, and
source-specific editorial posture.

This does not mean suppressing politically inconvenient facts or averaging
conflicting claims into a false midpoint. Neutrality is an evidence discipline:

- distinguish observed events from interpretation
- attribute allegations, denials, forecasts, and opinions
- state uncertainty when reporting is incomplete
- preserve material disagreement
- identify interested-party claims
- avoid laundering repetition into corroboration
- make unique factual Claims traceable to evidence

The primary reading surface should remain clean prose rather than an evidence
dashboard.

## Event Clusters and Articles

An Article is the canonical publication from one Outlet. Articles from
different Outlets are never deduplicated into one Article merely because they
cover the same subject.

An Event groups cross-Outlet Articles that report the same underlying
occurrence or tightly connected development. Clustering may use deterministic
information-retrieval signals, named entities, metadata, embeddings, or model
judgment, but the persisted result and its inputs must remain inspectable.

A generated Newspaper article is a new synthesis from an Event's reporting and
evidence. It is not a summary of one selected Article.

## Claim and Evidence Direction

A Claim is a discrete factual assertion that can be supported, contradicted,
qualified, attributed, or left uncertain.

The minimum internal model must be able to represent:

- the Claim text or structured proposition
- the Event and source Article context
- supporting or contradicting evidence
- the originating evidence or reporting chain
- whether the source is independent of another source
- whether the speaker has a direct interest in the Claim
- whether the Claim is observation, allegation, denial, estimate, prediction,
  opinion, or primary-record fact
- confidence and uncertainty metadata
- the exact source location used by a Citation

The final vocabulary should remain small enough to implement and audit. It
should describe evidentiary meaning without pretending the application can
compute objective truth as one score.

## Interested Parties and Official Statements

Official status does not make a statement neutral or true.

When a company, government, campaign, defendant, plaintiff, union, advocacy
group, or other interested entity speaks:

- the statement is evidence that the statement was made
- first-hand factual material may support appropriately scoped Claims
- denials and self-exonerating Claims remain attributed
- the statement does not automatically counterbalance independent reporting
  numerically
- the prose should identify material conflicts between the statement and other
  evidence

This treatment applies equally to a trusted source and a distrusted one. Source
weight influences prominence and admission; Claim support depends on the
evidence relationship.

## Uncertainty and Disagreement

The Newspaper should cover important unfolding or disputed Events while
noting uncertainty.

It should distinguish:

- facts multiple independent evidence chains support
- facts reported by one source
- widespread Claims tracing to one origin
- interested-party statements
- unresolved disagreements
- facts that have changed as reporting developed

Uncertainty should normally appear in natural prose and attribution. Any
future confidence indicator must clarify rather than replace citations and
language.

Useful language may state that a Claim originated with one named source, that
other Outlets repeated it without independent confirmation, that no primary
evidence was available by cutoff, that officials had not commented, or that
available accounts conflict. Silence from higher-weight Outlets may be noted
when material, but it is not dispositive.

## Timelines and Publishing Time

For an unfolding Event, later Articles often contain a superset of earlier
reporting, but the system must not assume that a later Article is a complete or
more accurate replacement. It may add evidence, repeat old reporting, omit
details, correct a Claim, contradict earlier reporting, reframe without adding
information, or lag behind the best-known state. Publication time is evidence
about when information became available, not proof of correctness.

Synthesis should:

- order developments by occurrence time when known
- use publication and discovery time to reconstruct reporting sequence
- avoid allowing a later denial to erase earlier evidence
- recognize corrections, updated facts, and changed official accounts
- emphasize developments within the current edition window

## Story Threads

A Story Thread provides continuity across related Events and editions without
turning lifecycle management into a newsroom bureaucracy.

The only initial lifecycle states are:

- **Active:** recent Events may affect current synthesis or backstory.
- **Dormant:** no recent qualifying development; automatically reactivates
  when a related Event appears.

There is no initial resolved, closed, or permanently settled state.

Story Threads support:

- concise cross-edition backstory
- links to prior Edition Stories
- a timeline of material Events
- correction of mistaken cluster or continuity links

## The Story So Far

When a current Event belongs to an established Story Thread, the article may
show:

1. one visible sentence containing the minimum useful context
2. a collapsed concise backstory
3. links to relevant prior editions or timeline entries

The current article should focus on developments since the preceding edition.
Backstory must remain available for a reader who ignored the story yesterday
and became interested today.

New or genuinely standalone Events do not show the panel. Its contents are
generated as of the Edition cutoff and become part of the immutable Edition
Story snapshot.

## Citations

Unique factual Claims in synthesized articles require numbered citations.

- Citation markers appear in the prose.
- A numbered citation list appears at the bottom of the article.
- Each citation identifies the exact Article, document, statement, or other
  evidence used.
- Multiple citations may support one Claim.
- One numbered Citation may identify several genuinely independent supporting
  sources.
- A coverage-source list is not a substitute for Claim-level citations.
- Citations should preserve enough source-location information to audit the
  synthesis even if the upstream Article later changes.

The citation list should preserve source name, Article or document title,
publication time, link, and a short evidentiary annotation when useful, such as
original report, official statement, interested-party denial, or not
independently confirmed.

Common background knowledge and connective prose do not require gratuitous
citation density. Material unique facts, disputed facts, quotations,
statistics, allegations, denials, and primary-record Claims do.

## Corrections, Clarifications, and Retractions

Published editions remain immutable.

When an error is discovered after publication:

- create a correction, clarification, or retraction record
- include it in the Corrections section of a later edition
- link to the affected prior Edition and Edition Story
- state what the original Edition reported
- state what is now known
- explain whether the change is a correction, clarification, or full
  retraction
- preserve the original artifact

The archived original may display separate metadata indicating that a later
notice exists and link forward to it. The later notice links back, creating
bidirectional navigation without changing the historical text.

Pre-publication operator correction is limited to fixing persisted inputs and
relationships—such as a mistaken Event merge, split, classification, or
evidence link—then deterministically rerunning against the same sealed
manifest. The operator does not manually rewrite generated prose in place.

The initial operator design must provide explicit, reversible Event
merge/split and Story Thread link/unlink actions with an audit record. Detailed
interface design can evolve after real clustering results exist.
