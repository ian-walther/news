<h1>Product Experience and Edition Contract</h1>
<p><strong>Status:</strong> Current product decisions. This is a living source note; revise it to current truth rather than appending contradictory updates.</p>

<h2>Purpose</h2>
<p>This note defines how the mature Newspaper App feels to use: the relationship between the existing Reading Feed and the new Newspaper, the morning delivery experience, the front page, full articles, stable editions, edition length, and automatic publication behavior.</p>

<h2>Two Connected Product Experiences</h2>

<h3>Newspaper</h3>
<ul>
  <li>Event- and story-centric rather than article-centric.</li>
  <li>Combines coverage from multiple eligible sources into coherent synthesized articles.</li>
  <li>Publishes as a stable daily edition.</li>
  <li>Organizes stories into familiar newspaper sections.</li>
  <li>Explains what happened, what changed, what remains uncertain, and where important claims came from.</li>
  <li>Reads as clean newspaper prose rather than a dashboard, bullet-heavy briefing, or intelligence dossier.</li>
</ul>

<h3>Reading Feed</h3>
<ul>
  <li>Article-centric and conceptually identical to Ian's current RSS use case and the feed functionality already built in the repository.</li>
  <li>Lets Ian scan headlines and open individual articles that look interesting.</li>
  <li>Includes singleton reporting that has not become a multi-source event, plus essays, blogs, reviews, commentary, and entertaining pieces whose value is the article itself.</li>
  <li>Presents the original article or a hosted/extracted reader-mode version instead of forcing everything through synthesis.</li>
  <li>Remains a first-class half of the mature site rather than temporary scaffolding.</li>
</ul>

<p>The two experiences share source ingestion, extraction, topic classification, deduplication, and the underlying article corpus. Their output models remain deliberately different. Reading Feed articles may link to Newspaper stories they contributed to, and a singleton article may later become source material for a Newspaper story after broader coverage appears.</p>

<h2>Morning Delivery</h2>
<p>The intended experience begins when Ian's coffee is ready. The canonical Newspaper is a hosted, immutable daily edition. Email is the delivery mechanism. PDF rendering is deferred as optional polish or a vanity/export feature rather than part of the first Newspaper release.</p>

<p>The email is a lightweight delivery envelope rather than a second rendering of the Newspaper. It should include:</p>
<ul>
  <li>The edition date.</li>
  <li>A compact indication of available sections.</li>
  <li>Lead headlines.</li>
  <li>One prominent link to read the hosted edition.</li>
</ul>

<p>The website remains the only canonical rendering. It supports drill-down, numbered citations, Story So Far, source traversal, correction links, and archives without duplicating that product inside inconsistent email clients.</p>

<p>The edition should let Ian ignore uninteresting stories simply by not opening them. Reading must not feel like task management.</p>

<h2>Front-Page Story Unit</h2>
<p>Each story on the edition front page contains:</p>
<ul>
  <li>A neutral, system-written headline.</li>
  <li>A compact factual summary in paragraph form.</li>
  <li>A visible list of sources that covered the event.</li>
  <li>A clear path to open the full synthesized article.</li>
</ul>

<p>The source list communicates breadth of coverage. It does not imply that every listed source independently supports every sentence. Claim-level support belongs in citations and provenance. The front page is a clean reading surface, not an evidence dashboard.</p>

<h2>Full Article Experience</h2>
<p>Opening a story leads first to a longer, coherent newspaper article synthesized from the available reporting. The default experience is paragraph-form prose, not bullet lists, fact tables, or a structured dossier.</p>

<p>The article does not summarize one selected source. It constructs a new account from the factual substrate across the event's source cluster. Deeper evidence remains available without degrading the primary reading experience.</p>

<p>The reading layers are:</p>
<ol>
  <li><strong>Front page:</strong> headline, compact summary, and coverage sources.</li>
  <li><strong>Story article:</strong> readable synthesized newspaper prose.</li>
  <li><strong>Evidence and history:</strong> numbered citations, exact sources, prior coverage, timeline, and deeper provenance when deliberately opened.</li>
</ol>

<h2>Stable Daily Editions</h2>
<p>Each daily edition is a stable artifact. Its reporting window is defined by the interval since the preceding edition, not by what Ian personally read.</p>

<ul>
  <li>The system does not track reading history to decide how much backstory to show.</li>
  <li>Personalization comes from explicit configuration rather than behavioral surveillance or inferred engagement.</li>
  <li>Old editions remain browsable as an archive.</li>
  <li>Later developments belong in later editions rather than silently rewriting earlier ones.</li>
  <li>The stable-artifact model applies to hosted editions, PDFs, or both.</li>
</ul>

<h2>Edition Scheduling and Processing Window</h2>
<p>The edition uses two independently configurable scheduled boundaries:</p>
<ul>
  <li><strong>Content cutoff:</strong> Freeze the eligible input snapshot. Items discovered afterward belong to the next edition.</li>
  <li><strong>Delivery deadline:</strong> Seal the completed edition and send the delivery email.</li>
</ul>

<p>The gap between cutoff and delivery is an explicit processing window because extraction, clustering, evidence analysis, synthesis, citation validation, and rendering may take substantial time.</p>

<p>Processing duration must be observable so the schedule can be tuned. Useful edition-level and phase-level metrics include:</p>
<ul>
  <li>Total generation duration.</li>
  <li>Duration of eligibility, clustering, classification, evidence extraction, synthesis, citation validation, and rendering.</li>
  <li>Queue depth and worker concurrency.</li>
  <li>Story counts entering and surviving each phase.</li>
  <li>Failure and timeout counts.</li>
  <li>Median, percentile, worst-case, and trend data across recent editions.</li>
  <li>Remaining safety margin before delivery.</li>
</ul>

<p>The UI may recommend an earlier cutoff when recent runs consistently consume too much of the configured window, but the user retains control of both times.</p>

<h2>Automatic Publication Contract</h2>
<p>The delivery time is a hard deadline, not a target that slips while the system chases completeness.</p>

<ul>
  <li>At content cutoff, the system freezes the eligible input snapshot and begins or schedules processing against that snapshot.</li>
  <li>At delivery deadline, it automatically seals and publishes whatever complete, valid stories are ready.</li>
  <li>The edition is emailed automatically without waiting for manual review.</li>
  <li>Broken or half-generated articles do not enter the edition.</li>
  <li>One failed source, extraction, cluster, or synthesis must not block the entire Newspaper.</li>
  <li>Omitted work and failures remain clearly visible in the operator interface.</li>
  <li>Work completed after the deadline rolls into the next edition rather than mutating the sealed artifact.</li>
  <li>The sealed edition remains immutable.</li>
</ul>

<p>The minimum successful edition is deliberately simple:</p>
<ul>
  <li><strong>One or more completed valid stories:</strong> Publish on time regardless of how thin the edition is.</li>
  <li><strong>Zero completed stories:</strong> Record a failed edition run and send a failure notification instead of fabricating, reusing, or emailing an empty Newspaper.</li>
</ul>

<p>No minimum page count, section count, or subjective “substantial enough” threshold exists. Ian expects a large source universe, so the zero-story boundary should be exceptional while remaining trivial to enforce.</p>

<h2>Deterministic, Non-Mutable Generation</h2>
<p>An in-progress edition is not a manually editable draft. Mutable clustering, prose, section placement, citations, or story selection would create a second editorial workflow and undermine reproducibility.</p>

<p>Each run is generated from a sealed manifest containing:</p>
<ul>
  <li>Eligible Article and extraction revisions.</li>
  <li>Source policies and effective weights.</li>
  <li>Taxonomy version.</li>
  <li>Story/event inputs.</li>
  <li>Model, prompt, and schema versions.</li>
  <li>Content cutoff and delivery deadline.</li>
  <li>Processing implementation versions.</li>
</ul>

<p>The operator can inspect why an output occurred but cannot manually edit the edition in place. Retries re-execute failed work against the same snapshot. Configuration changes affect future runs. Published errors use the correction, clarification, and retraction process rather than mutation.</p>

<h2>Edition Length</h2>
<p>The Newspaper has no fixed story count, page count, or target reading length. Its size is derived from what the system discovers happened during the edition window. Quiet days may produce a thin edition; major news days may produce a large one. Empty sections may disappear.</p>

<h2>Open Decisions</h2>
<ul>
  <li>The actual default cutoff, delivery time, and timezone configuration.</li>
  <li>Whether supplemental editions ever exist for extraordinary late-breaking developments; the default remains next-edition inclusion.</li>
  <li>Archive navigation and stable LAN URL shape.</li>
</ul>
