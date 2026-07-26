<h1>Outlet and Upstream Processing Domain Model</h1>
<p><strong>Status:</strong> Settled product/domain direction for the Newspaper expansion. This is a living source note; revise it to current truth rather than appending contradictory updates.</p>

<h2>Why the Model Is Becoming More Opinionated</h2>
<p>V1 intentionally used generic intake feeds, optional intake groups, and generated output feeds. That flexibility was useful while proving feed ingestion, deduplication, extraction, digestion, and publishing. The personalized Newspaper now needs explicit real-world concepts for source weighting, coverage breadth, topic policy, evidence provenance, and cross-outlet clustering.</p>

<p>The previous interpretation that intake groups existed to group related content for reading was a miscommunication. Related content should be grouped for consumption through generated output-feed membership. The durable role of the existing intake-group machinery is outlet-wide deduplication across multiple feeds from the same real-world editorial source.</p>

<p>The app should therefore become opinionated at the real domain seams instead of preserving generic abstractions that make every later policy ambiguous.</p>

<h2>Canonical Vocabulary</h2>

<h3>Outlet</h3>
<p>An <strong>Outlet</strong> represents one real-world editorial or publishing identity, such as Reuters, Ars Technica, The Wall Street Journal, a local newspaper, or a local television station.</p>

<p>Outlet is preferred over Publisher because Publisher may later mean a corporate owner such as Hearst, Condé Nast, or News Corp. Corporate ownership and outlet affiliation can be added as separate relationships if they become useful.</p>

<p>An Outlet is:</p>
<ul>
  <li>The required logical parent of its normal input feeds.</li>
  <li>The deduplication boundary across those feeds.</li>
  <li>The unit counted for Newspaper coverage breadth.</li>
  <li>The default scope for Newspaper enablement and source weighting.</li>
  <li>The default scope for topic and Local policies.</li>
  <li>The durable home for display identity, canonical domains, notes, and future source-quality observations.</li>
</ul>

<h3>Input Feed</h3>
<p>An <strong>Input Feed</strong> is one RSS or Atom discovery endpoint belonging to an Outlet.</p>

<p>It owns transport and endpoint concerns:</p>
<ul>
  <li>Feed URL.</li>
  <li>Fetch enabled state and cadence.</li>
  <li>HTTP cache validators and last-fetch state.</li>
  <li>Feed-specific extraction or classification overrides.</li>
  <li>Raw upstream categories, feed title, and other classification hints.</li>
  <li>Optional narrower generated RSS membership.</li>
</ul>

<h3>Output Feed</h3>
<p>An <strong>Output Feed</strong> is a generated RSS product used to group content for consumption. Technology, Finance, Automotive, Local, source bundles, and any other user-defined reading group belong here.</p>

<p>Output feeds select whole Outlets and/or individual Input Feeds:</p>
<ul>
  <li>Including an Outlet means all current and future enabled feeds belonging to it.</li>
  <li>Including an individual Input Feed allows precise selection of only part of an Outlet's feed surface.</li>
  <li>Output membership does not define outlet identity, deduplication, Newspaper eligibility, extraction enrollment, or classification ownership.</li>
</ul>

<h3>Article Appearance</h3>
<p>The existing concept currently named Article Source is actually a discovery record: it says that an article appeared through a particular Input Feed and Raw Item.</p>

<p>It should be renamed <strong>Article Appearance</strong> or <strong>Feed Appearance</strong>. This preserves an essential distinction:</p>
<ul>
  <li>An <strong>appearance</strong> records where the app discovered a published article.</li>
  <li>An <strong>outlet</strong> identifies the publishing/editorial brand.</li>
  <li>A <strong>reporting dependency</strong> records that one article relies on another report.</li>
  <li>A <strong>claim citation/source</strong> records evidence supporting a synthesized claim.</li>
</ul>

<p>Using Source for all four concepts would become a semantic tar pit once provenance and claims are first-class.</p>

<h2>Canonical Relationship</h2>
<pre>Outlet
  └── Input Feeds
        └── Raw Item / Article Appearances
              └── Canonical Articles
                    ├── Generated RSS Output Feeds
                    └── Newspaper discovery, clustering, and generation</pre>

<p>A canonical Article normally belongs to one publishing Outlet and can have several appearances across that Outlet's feeds. Similar articles published by different Outlets remain distinct canonical Articles and are connected later through cross-outlet event clustering rather than intake deduplication.</p>

<p>Syndication remains a separate provenance problem. A local site may host an AP article: the local brand is the publishing outlet/host, while AP may be the originating reporting source. That dependency should eventually be modeled explicitly rather than corrupting basic article identity.</p>

<h2>Intake Group Becomes Outlet</h2>
<p>There is no longer a product reason to preserve Intake Group as a separate generic abstraction. Its important existing role—deduplicating related feeds from one source—maps directly to Outlet.</p>

<p>The intended semantic migration is:</p>
<ul>
  <li><code>intake_groups</code> becomes <code>outlets</code>.</li>
  <li><code>intake_group_id</code> becomes <code>outlet_id</code>.</li>
  <li><code>generated_feed_intake_groups</code> becomes <code>generated_feed_outlets</code>.</li>
  <li>Group-based deduplication becomes outlet-based deduplication.</li>
  <li>Previously ungrouped Input Feeds receive an Outlet rather than remaining identity-less.</li>
  <li>Duplicated outlet-name strings become proper Outlet relationships or deliberate immutable presentation snapshots.</li>
  <li><code>ArticleSource</code> and <code>article_sources</code> become Article Appearance terminology.</li>
</ul>

<p>This migration keeps the useful grouping and deduplication machinery while giving it the domain meaning it should have had. A separate Feed Group or Intake Boundary should only be introduced later if a concrete non-outlet deduplication requirement appears.</p>

<h2>Classify Articles Independently</h2>
<p>The app should classify extracted canonical Articles against its own controlled taxonomy. It should not treat sub-feed membership or publisher categories as authoritative classification.</p>

<p>Upstream feed metadata remains useful as a cheap and explainable prior:</p>
<ul>
  <li>An article discovered in WSJ Technology receives a strong Technology hint.</li>
  <li>Feed categories, titles, and source tags remain preserved as classification evidence.</li>
  <li>The app-owned classifier may confirm, add to, or override those hints.</li>
  <li>Classification produces one primary Newspaper section plus controlled secondary tags.</li>
</ul>

<p>App-owned classification is necessary because publisher taxonomies are inconsistent, duplicated, liable to drift, and unable to express the source-by-topic and geographic policies already chosen for the Newspaper.</p>

<h2>Move Processing Upstream of Outputs</h2>
<p>The Newspaper requires a complete enriched article pool that exists independently of generated RSS membership.</p>

<pre>Outlet / Input Feed policy
  → fetch
  → canonicalize and deduplicate within Outlet
  → extract once at Article level
  → classify once at Article level
  → shared enriched Article pool
      ├── generated RSS selection and rendering
      └── Newspaper eligibility, clustering, and generation</pre>

<p>The first architectural prerequisite for Newspaper work is therefore moving extraction enrollment and later classification upstream from output-feed pipeline steps to Outlet/Input Feed/Article policy.</p>

<ul>
  <li>A source can participate only in the Newspaper without fake output-feed membership.</li>
  <li>Extraction artifacts remain article-level reusable state.</li>
  <li>Classification artifacts are produced once and reused by all outputs.</li>
  <li>Generated RSS feeds consume enriched Articles but do not cause those Articles to become eligible for processing.</li>
  <li>Newspaper clustering operates across the complete eligible article pool.</li>
</ul>

<p>The current code already stores endpoint fetch state on Input Feeds. The deeper relocation is processing enrollment and ownership: extraction and classification must be upstream domain operations rather than side effects of generated RSS publication.</p>

<h2>First Newspaper Input Scope</h2>
<p>Before the first Newspaper run, Ian expects to configure many ordinary feeds and organize them under Outlets. This existing ingestion surface is sufficient to create a useful corpus after upstream extraction and classification are available.</p>

<p>The following source classes are explicitly deferred from the first Newspaper release:</p>
<ul>
  <li>Twitter-specific ingestion.</li>
  <li>Newsletter-specific ingestion.</li>
  <li>Automated official-source discovery.</li>
</ul>

<p>Configured RSS/Atom feeds plus the existing extraction tiers should first prove weighted admission, clustering, evidence-aware synthesis, hosted editions, and scheduled delivery.</p>

<h2>Design Principle</h2>
<blockquote>
  <p>Outlet is who published it and the deduplication boundary. Input Feed is where it was discovered. Output Feed is where the user wants to read it.</p>
</blockquote>

<p>Opinionated domain modeling does not reduce useful extensibility. It moves extensibility to the real seams: Outlets, feeds, appearances, articles, events, claims, and outputs each have one clear role.</p>
