<h1>Story, Event, Timeline, and Section Model</h1>
<p><strong>Status:</strong> Current high-level product model. This is a living source note; revise it to current truth rather than appending contradictory updates.</p>

<h2>Purpose</h2>
<p>This note defines continuing stories, discrete events, claim/development timelines, daily edition articles, optional backstory, reader-facing time order, and the controlled section/tag model.</p>

<h2>Continuing Story Structure</h2>
<p>The system should not allow one article cluster to grow indefinitely. It should distinguish several related layers:</p>

<ol>
  <li><strong>Story thread:</strong> A durable continuing subject or unfolding narrative.</li>
  <li><strong>Event:</strong> A concrete occurrence within that story.</li>
  <li><strong>Claim/development timeline:</strong> What happened or was alleged, when it happened, when it was first reported, and how its support changed.</li>
  <li><strong>Daily edition article:</strong> A prose synthesis emphasizing relevant developments since the preceding edition cutoff.</li>
  <li><strong>Story So Far:</strong> An optional contextual reconstruction from the accumulated history.</li>
</ol>

<p>For example, “Federal Reserve monetary policy” may be a continuing story thread. A rate decision, press conference, and later inflation report are separate events or developments connected to that thread. The edition synthesizes what is new without collapsing the entire subject into one permanent blob.</p>

<h2>Minimal Story Lifecycle</h2>
<p>Story lifecycle should remain deliberately simple:</p>
<ul>
  <li><strong>Active:</strong> The thread has current qualifying developments.</li>
  <li><strong>Dormant:</strong> No qualifying developments have appeared for the configured inactivity period.</li>
  <li>New related activity automatically returns a dormant thread to Active.</li>
  <li>No automatic Resolved, Finished, or Closed state is needed.</li>
  <li>Merge and split operations exist only to correct clustering identity mistakes.</li>
</ul>

<p>The inactivity duration is an implementation-tuning value rather than a major product concept. Nothing needs to be declared permanently settled before the heat death of the universe.</p>

<h2>Later Articles Are Not Assumed to Be Perfect Supersets</h2>
<p>Coverage of an unfolding event will often repeat earlier information and add new details. That pattern is useful, but the system must not assume every later article is a reliable superset.</p>

<p>Later articles may:</p>
<ul>
  <li>Add genuinely new claims or evidence.</li>
  <li>Repeat older reporting.</li>
  <li>Omit prior details.</li>
  <li>Correct earlier claims.</li>
  <li>Contradict earlier reporting.</li>
  <li>Reframe the event without adding information.</li>
  <li>Lag behind the best-known current state.</li>
</ul>

<p>The system therefore needs temporal, source-aware claim comparison rather than simple replacement of old articles with newer ones.</p>

<h2>Daily Development Article</h2>
<ul>
  <li>The main article focuses primarily on developments since the preceding edition.</li>
  <li>It does not retell the entire timeline every morning.</li>
  <li>It remains understandable without requiring the reader to have read yesterday's edition.</li>
  <li>Earlier edition articles, the underlying timeline, and evidence remain available for deeper traversal.</li>
</ul>

<h3>The Story So Far</h3>
<p>Continuing stories show a collapsed <strong>The Story So Far</strong> panel beneath the current article:</p>
<ul>
  <li>One visible sentence summarizes the necessary prior context.</li>
  <li>Expanding it reveals a concise prose backstory.</li>
  <li>The backstory links to relevant prior edition articles and timeline entries.</li>
  <li>New or genuinely standalone events do not show the panel.</li>
  <li>The backstory is generated as of the edition cutoff and becomes part of the edition's stable snapshot.</li>
</ul>

<h2>Timeline Semantics</h2>
<p>The reader-facing timeline should be ordered primarily by when real-world events happened. Publication and first-report times remain visible as secondary provenance.</p>

<p>Both clocks matter:</p>
<ul>
  <li><strong>Event time</strong> explains the real-world sequence.</li>
  <li><strong>Publication or first-report time</strong> explains how public knowledge evolved, what was known by an edition cutoff, and whether later articles corrected or merely repeated earlier information.</li>
</ul>

<p>If event time is unknown, first-known publication time may serve as the provisional ordering signal while uncertainty remains explicit.</p>

<h2>Controlled Section Taxonomy</h2>
<p>The Newspaper starts with a fairly extensive controlled catalog rather than arbitrary user-created semantics. The initial top-level sections are:</p>
<ul>
  <li>World</li>
  <li>United States</li>
  <li>Local</li>
  <li>Business</li>
  <li>Finance &amp; Markets</li>
  <li>Technology</li>
  <li>Science</li>
  <li>Health</li>
  <li>Environment &amp; Energy</li>
  <li>Sports</li>
  <li>Automotive</li>
  <li>Arts &amp; Culture</li>
  <li>Entertainment</li>
</ul>

<p>The initial controlled cross-cutting tags include:</p>
<ul>
  <li>Politics</li>
  <li>Elections</li>
  <li>Courts</li>
  <li>Regulation</li>
  <li>Economy</li>
  <li>Labor</li>
  <li>Education</li>
  <li>Public Safety</li>
  <li>National Security</li>
  <li>Climate</li>
  <li>Space</li>
  <li>Artificial Intelligence</li>
  <li>Gaming</li>
  <li>Real Estate</li>
  <li>Media</li>
</ul>

<p>Politics is deliberately a tag rather than a top-level section. Political stories are placed according to their primary real-world domain or geography—World, United States, Local, Business, Finance, or another section—and tagged Politics plus more specific concepts such as Elections, Courts, or Regulation.</p>

<p>Longform, opinion, lifestyle, food, and travel are initially better treated as Reading Feed categories because they usually describe an article form or interest rather than a cluster of developing events.</p>

<h2>Taxonomy Must Be Evolvable</h2>
<p>The controlled vocabulary is an initial product vocabulary, not a permanent prison.</p>

<ul>
  <li>Sections and tags are durable reference records with stable identifiers rather than enums hard-coded throughout the application.</li>
  <li>Display name, order, and enabled state are independently configurable.</li>
  <li>New categories can be introduced without a database schema migration or broad code rewrite.</li>
  <li>Used categories are retired, aliased, merged, or split rather than destructively deleted.</li>
  <li>Renames do not break source policies or historical editions.</li>
  <li>Classifier configuration is generated from the active taxonomy.</li>
  <li>Published editions snapshot their placement and tags so later taxonomy changes do not rewrite history.</li>
</ul>

<h2>Placement and Tags</h2>
<p>Every Newspaper story has:</p>
<ul>
  <li>One canonical primary section controlling placement.</li>
  <li>Any number of secondary controlled tags.</li>
  <li>One canonical article, never duplicated across multiple sections.</li>
</ul>

<p>A Federal Reserve decision may be placed in Finance &amp; Markets while carrying tags for Politics, Regulation, Economy, and related concepts. Tags support filtering, navigation, source policy, and topic-specific weighting without padding the edition through duplication.</p>

<h2>Local Placement and Geography</h2>
<p>Local covers configured municipality, county, metro, state, and other relevant place layers. Stories appear once in Local and carry the matching geographic and topical tags.</p>

<p>The geographic classifier must distinguish events occurring within a place or directly affecting it from stories that merely originate at a local publisher or mention the place incidentally.</p>

<h2>Open Decisions</h2>
<ul>
  <li>The inactivity duration used to move an Active thread to Dormant.</li>
  <li>The UI and data shape for locality profiles and multiple places of interest.</li>
  <li>Rules for assigning a primary section when several apply.</li>
  <li>The minimal automated and operator rules for correcting mistaken event merges or splits.</li>
  <li>How continuing story threads are initially created and linked.</li>
  <li>The exact UI for timelines, prior editions, and Story So Far.</li>
  <li>Future additions, aliases, merges, or splits in the initial section and tag vocabulary.</li>
</ul>
