<h1>Source Configuration, Admission, and Ranking</h1>
<p><strong>Status:</strong> Current product decisions. This is a living source note; revise it to current truth rather than appending contradictory updates.</p>

<h2>Purpose</h2>
<p>This note defines the configured source universe, routing between Reading Feed and Newspaper, source-by-topic policy, weighted story admission, prominence ranking, coverage breadth, evidentiary independence, singleton behavior, and alternative-source direction.</p>

<h2>User-Owned Source Universe</h2>
<p>Top stories emerge from the sources Ian explicitly configures. The system should not import a hidden global editorial agenda or infer one from reading behavior.</p>

<p>A story becomes prominent when eligible configured sources cover the same underlying event. Prominence is derived primarily from weighted coverage after clustering, while factual confidence is evaluated separately.</p>

<h2>Sources Are Independent From Outputs</h2>
<p>A configured upstream source exists independently from every output. Source ingestion, generated RSS membership, and Newspaper participation are separate controls.</p>

<ol>
  <li><strong>Ingestion enabled:</strong> Whether the app fetches the source.</li>
  <li><strong>Generated RSS memberships:</strong> Zero, one, or many output RSS feeds that receive eligible articles from the source.</li>
  <li><strong>Newspaper enabled and policy:</strong> Whether and how the source contributes to Newspaper discovery, admission, ranking, evidence, and sections.</li>
</ol>

<p>Disabling Newspaper participation does not remove a source from generated RSS outputs. A source can also be Newspaper-only without belonging to any output RSS feed. Output-feed filtering remains independent from Newspaper filtering.</p>

<p>This distinction is especially important for local sources. A source may remain fully visible in configured RSS outputs, including its national coverage, while its Newspaper policy contributes only geographically relevant local reporting.</p>

<h2>Configuration Scope and Inheritance</h2>
<p>Newspaper trust and policy usually attach to a logical outlet or intake group, while individual input feeds are discovery plumbing that may need narrower exceptions.</p>

<p>Policy inheritance should follow:</p>
<ol>
  <li>Logical outlet or intake-group defaults.</li>
  <li>Individual input-feed overrides.</li>
  <li>Topic-specific overrides.</li>
  <li>Geographic or Local overrides.</li>
</ol>

<p>The most specific applicable rule wins. Generated RSS output memberships remain a separate many-to-many configuration rather than inheriting from Newspaper policy.</p>

<h2>Source Weighting</h2>
<p>All new Outlets begin with a base weight of <code>1.0</code>. Weights are literal relative multipliers:</p>
<ul>
  <li><code>1.0</code> contributes one normal source vote.</li>
  <li><code>2.0</code> contributes twice as much as a default source.</li>
  <li><code>0.5</code> contributes half as much.</li>
</ul>

<p>Ian can tune weights manually over time because sources improve, degrade, change staff, or become less useful. Source medium is not a proxy for reliability. Wire service, newspaper, newsletter, blog, press release, and Twitter account describe formats or roles, not inherent quality.</p>

<p>Overrides are absolute effective weights rather than compound multipliers. The policy hierarchy is:</p>
<ol>
  <li>Outlet base weight.</li>
  <li>Individual Input Feed override.</li>
  <li>Topic override.</li>
  <li>Local or locality-specific override.</li>
</ol>

<p>The most specific applicable override replaces the inherited value. This avoids surprising multiplication chains and keeps admission explainable.</p>

<p>The UI should show the effective weight next to every override, identify where an inherited value came from, show when a more-specific rule supersedes it, and provide a clear reset-to-inheritance action. It may also preview whether the current effective value clears relevant admission thresholds.</p>

<p>For example, Ars Technica may retain a normal base weight, receive a high Technology weight, and exclude or heavily reduce Politics. A trusted local source may receive a Local weight high enough to qualify singleton local coverage.</p>

<p>Automatic reputation changes are not required. A future system may surface evidence such as frequent corrections, excessive repetition, poor extraction, or low original-information yield, but it should suggest changes rather than silently rewrite Ian's trust model.</p>

<h2>Singleton Material</h2>
<p>If only one outlet covers something, it normally remains in the Reading Feed rather than becoming a synthesized Newspaper story.</p>

<p>Singleton material is not necessarily low quality. It may be niche original reporting, an essay, analysis, blog post, review, entertaining feature, or an early report that later becomes part of a Newspaper story.</p>

<h2>Local News Is a Distinct Policy Family</h2>
<p>Local is more than a display section. It needs geographic configuration, local-source policies, and different admission economics from national or broad-topic news.</p>

<h3>Locality Profile</h3>
<p>The user configures relevant geographic layers such as municipality, county, metro area, state, and other places of continuing interest.</p>

<p>A story is locally relevant when it:</p>
<ul>
  <li>Occurs within a configured place.</li>
  <li>Is an action by a government or institution governing that place.</li>
  <li>Applies specifically to that place.</li>
  <li>Has a concrete, direct effect on that place.</li>
</ul>

<p>Local relevance is determined by the event's relationship to a configured place, not by the publisher's location. Publication by a local outlet, an incidental place-name mention, quoting a local resident, generic national impact framing, or syndicated national coverage does not make a story Local.</p>

<p>A federal law applying only to Pennsylvania can qualify as Local for a Pennsylvania locality profile even though Congress enacted it. A nationwide federal law remains US unless it has an additional concrete place-specific effect.</p>

<h3>Local Source Policies</h3>
<p>A source may be configured as <strong>local coverage only</strong> for Newspaper participation. Its nonlocal articles remain available in generated RSS output feeds; they are excluded only from Newspaper contribution under that policy.</p>

<p>Sources can have a distinct Local weight in addition to their default and topic weights. Locality-specific overrides may exist when a source is excellent for one municipality or county but weak statewide.</p>

<h3>Local Singleton Admission</h3>
<p>Local reporting often lacks the multi-outlet breadth expected of national stories. One sufficiently high-weight Local source can therefore qualify a geographically relevant story for Newspaper synthesis when its effective Local weight clears the Local singleton threshold.</p>

<p>A Local singleton article must remain honest about its evidence base. The source stays visible, unique claims receive citations, and the prose must not imply corroboration that does not exist. Primary documents strengthen the story when available but are not mandatory.</p>

<h2>Admission Is Weighted and Continuous</h2>
<p>A small number of low-weight sources should not automatically make a story publishable. However, low source weights are not a black-and-white exclusion rule. Widespread lower-weight coverage can qualify because absence from favored outlets may reflect their own shared blind spots.</p>

<p>The initial admission paths are:</p>
<ol>
  <li><strong>Normal nonlocal admission:</strong> At least two distinct eligible Outlets and a combined effective weight of at least <code>2.0</code>.</li>
  <li><strong>Local singleton admission:</strong> One geographically relevant Outlet whose effective Local weight reaches the configured Local threshold.</li>
  <li><strong>Primary-evidence exception:</strong> One eligible reporting Outlet plus a primary document that directly establishes the core event.</li>
</ol>

<p>Admission thresholds remain configurable, but <code>2.0</code> is the explainable initial default for ordinary nonlocal coverage.</p>

<p>The primary-evidence exception is scoped claim by claim. A court ruling, enacted law, regulatory filing, official vote record, or similar document can directly establish the event. A company denial establishes that the company denied an allegation; it does not act as a second source corroborating the accusation being denied.</p>

<blockquote>
  <p>Publication is determined by configurable weighted coverage with no mandatory high-trust anchor. Primary evidence can satisfy an admission path only when it actually establishes the core event.</p>
</blockquote>

<h2>Prominence, Breadth, and Confidence Are Different</h2>
<ul>
  <li><strong>Coverage breadth:</strong> How many distinct outlets or configured sources chose to discuss the story. This affects whether the story matters enough to cover.</li>
  <li><strong>Weighted prominence:</strong> How strongly those sources contribute under Ian's global and topic-specific policies. This affects admission and ordering.</li>
  <li><strong>Evidentiary independence:</strong> How many genuinely independent reporting or evidence chains support a claim. This affects factual confidence, not whether discussion itself is newsworthy.</li>
</ul>

<p>Twenty low-weight outlets repeating one allegation may make that allegation Newspaper-worthy because it has become widespread and consequential. It does not create twenty independent confirmations. The synthesized article must explain the actual evidence structure.</p>

<h2>Duplicates, Syndication, and Repetition</h2>
<ul>
  <li>Repeated articles from the same source do not multiply that source's contribution.</li>
  <li>Exact syndication and substantially duplicate copies are collapsed or attributed to their origin.</li>
  <li>Distinct outlets independently choosing to discuss the same originating report may contribute to coverage breadth and prominence.</li>
  <li>Those outlets do not create independent factual confirmation when their claims trace to one source.</li>
  <li>Ranking and article language should remain explainable in terms of both coverage and evidence chains.</li>
</ul>

<p>Widespread repetition earns attention, not truth.</p>

<h2>Primary and Alternative Sources</h2>
<p>The Newspaper should weave nontraditional and primary-source-adjacent material into stories when available:</p>
<ul>
  <li>Whitelisted trustworthy Twitter accounts.</li>
  <li>Newsletters.</li>
  <li>Press releases.</li>
  <li>Agency pages.</li>
  <li>Official statements and documents.</li>
  <li>Local reporting.</li>
  <li>Trade blogs and niche beat sources.</li>
</ul>

<p>Primary documents and official statements are not required for a story to publish. When available, they should be included and can provide high-value evidence within the scope they are qualified to establish. They may contribute to admission and support, but their evidentiary meaning is claim-specific and governed by the editorial-evidence model rather than a generic “official equals true” rule.</p>

<p>In the dream version, the system discovers relevant official statements and press releases automatically. This remains a desired direction rather than a settled first-release requirement. A bounded path should associate known entities with curated official channels before attempting unrestricted discovery.</p>

<h2>Explainability</h2>
<p>The operator should be able to understand why a story qualified and why it ranked where it did, including:</p>
<ul>
  <li>Eligible covering sources.</li>
  <li>Applicable global and topic-specific weights.</li>
  <li>Duplicate or syndication collapses.</li>
  <li>Known citation or dependency chains.</li>
  <li>Combined admission/prominence score.</li>
</ul>

<h2>Open Decisions</h2>
<ul>
  <li>The permitted UI range and increment for numeric weights.</li>
  <li>Whether configured sections beyond Local eventually receive threshold overrides.</li>
  <li>How official documents contribute numerically when they support only part of an event.</li>
  <li>How source dependencies and syndicated families are detected and represented.</li>
  <li>The final UI for Outlet defaults, feed overrides, output memberships, topic rules, Local rules, effective weights, and exclusions.</li>
  <li>How automated official-source discovery is bounded and verified.</li>
</ul>
