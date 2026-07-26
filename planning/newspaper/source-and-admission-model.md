# Source and Admission Model

## User-Owned Source Universe

Top stories emerge from sources the user explicitly configures. The system
must not import a hidden global editorial agenda or infer one from engagement
history.

Source medium is not a proxy for reliability. A wire service, newspaper,
newsletter, blog, press release, or whitelisted social account may receive any
weight justified by the user's experience with it.

## Sources Are Independent From Outputs

An Outlet and its Input Feeds exist independently from every output. The
controls are separate:

1. **Ingestion enabled:** whether an Input Feed is fetched.
2. **Reading Feed memberships:** zero, one, or many Output Feeds that receive
   eligible Articles.
3. **Newspaper participation:** whether and how the Outlet or feed contributes
   to discovery, admission, ranking, evidence, sections, topics, and Local
   coverage.

Disabling Newspaper participation does not remove an Article from generated
RSS. An Outlet can also be Newspaper-only without fake Output Feed membership.

Output Feed membership can include all enabled Input Feeds from an Outlet or
specific Input Feeds. Related feeds are grouped for reading through Output Feed
membership, not by inventing a second source-group abstraction.

## Policy Inheritance

The initial policy hierarchy is:

1. Outlet base policy.
2. Input Feed override.
3. Topic-specific override.
4. Local or locality-specific override.

The most specific applicable rule wins. Generated RSS membership is a
separate many-to-many relationship and does not inherit from Newspaper policy.

## Source Weighting

Every new Outlet begins with a base weight of `1.0`.

- `1.0` contributes one normal source vote.
- `2.0` contributes twice the default contribution.
- `0.5` contributes half the default contribution.

Weights are manually configurable because sources improve, degrade, change
staff, or become less useful. The application may later surface supporting
metrics, but it must not silently rewrite the user's trust model.

Overrides are absolute effective weights, not compounding multipliers. A Topic
or Local override replaces the inherited value.

The UI should show:

- the effective weight
- the value's inheritance source
- whether a more-specific rule supersedes it
- a reset-to-inheritance action
- the relevant admission threshold where useful

For example, Ars Technica may have a normal base weight, a high Technology
weight, and an exclusion or low weight for Politics. A trusted Local source
may have a Local weight high enough to qualify a singleton Local event.

## Admission Paths

The initial Newspaper admission paths are:

1. **Normal nonlocal admission:** at least two distinct eligible Outlets and a
   combined effective weight of at least `2.0`.
2. **Local singleton admission:** one geographically relevant Outlet whose
   effective Local weight reaches the configured Local threshold.
3. **Primary-evidence exception:** one eligible reporting Outlet plus a primary
   document that directly establishes the core event.

The thresholds are configurable, with `2.0` as the initial ordinary nonlocal
default.

No particular high-trust Outlet or wire service is a mandatory admission
anchor. Qualification comes from the configured weighted source universe and
the applicable admission path.

If only one Outlet covers an Event and neither singleton exception applies,
the Article remains in the Reading Feed rather than becoming a synthesized
Newspaper story. Singleton material may be excellent original reporting,
analysis, an essay, a review, a niche blog post, or simply the first report of
an Event that later develops broader coverage.

A large number of lower-weight Outlets can overcome weak individual weights.
This protects against merely replacing the bias of distrusted sources with the
shared blind spots of favored sources.

A primary document only establishes what it is qualified to establish. A
court ruling can establish that the court ruled. A company statement denying
an allegation establishes that the denial occurred; it does not corroborate
the company's innocence or act as a second source for the accusation.

## Prominence Is Not Confidence

The system must keep three concepts separate:

- **Coverage breadth:** how many distinct eligible Outlets discuss the Event.
- **Weighted prominence:** the sum of applicable effective Outlet weights used
  for admission and ordering.
- **Evidentiary independence:** how many genuinely independent evidence or
  reporting chains support a Claim.

Repeated articles from one Outlet contribute one Outlet vote. Exact
syndication and substantially duplicated copies should collapse or point to
their origin.

Distinct Outlets independently choosing to repeat one originating allegation
can increase breadth and prominence because the allegation has become
consequential. They do not create independent factual confirmation.

Widespread repetition earns attention, not truth.

## Local Policy

Local is both a section and a distinct policy family.

A locality profile may contain:

- municipality
- county
- metro area
- state
- other places of continuing interest

An Event is locally relevant when it:

- occurs within a configured place
- is an action by a government or institution governing that place
- applies specifically to that place
- has a concrete, direct effect on that place

Publisher location, incidental place-name mentions, generic national impact,
quoting a local resident, or syndicated national coverage do not make an Event
Local.

A federal law applying only to Pennsylvania can be Local for a Pennsylvania
profile. A nationwide law remains US unless it produces an additional concrete
place-specific Event or effect.

An Outlet may use a **Local coverage only** Newspaper policy while its nonlocal
articles remain in configured Reading Feeds. Outlet, Topic, and
locality-specific weights can differ.

Local singleton synthesis must remain explicit about its evidence base.
Unique claims receive citations and the article must not imply corroboration
that does not exist.

## Alternative and Primary Sources

The model should eventually support:

- whitelisted social accounts
- newsletters
- press releases
- agency pages
- official statements and documents
- trade blogs and niche beat sources

Primary material is not mandatory for publication. When available, it can
provide high-value evidence and participate in the primary-evidence admission
path only for Claims it directly establishes.

Automatic official-source discovery is deferred. A safer intermediate design
associates known entities with curated official channels.

## Explainability

For every admitted or rejected Event, the operator should be able to inspect:

- eligible covering Outlets and Input Feeds
- applicable base and override policies
- effective weights
- duplicate and syndication collapses
- known reporting dependencies or common origins
- combined admission and prominence score
- which admission path, if any, was satisfied
- evidence limitations that affect prose but not prominence
