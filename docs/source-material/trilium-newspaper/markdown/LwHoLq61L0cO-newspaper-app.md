<h2>Top-Level Thread</h2>
<p>This note snapshots the conceptual direction that emerged while thinking through the newspaper/news aggregation app. The current app is still working against normal RSS feeds, but the more interesting future direction is aggregating from what the owner described as “tier 2 sources.”</p>

<h2>Current Framing</h2>
<p>The normal RSS feeds are the clean training wheels: predictable structure, known outlets, steady cadence, and a relatively straightforward path from article ingestion to summarization.</p>

<p>The more interesting piece is aggregating news from tier 2 sources: local reporting, trade blogs, agency pages, press releases, primary-source-adjacent sources, niche beat writers, and other sources that may be noisy or incomplete individually but valuable collectively.</p>

<p>The broader goal is not just “AI summaries of articles.” It is closer to taking messy, scattered information and reconstructing a useful, honest account of what happened.</p>

<h2>Identity Of The Project</h2>
<p>The project has a strong conceptual identity as a kind of de-shitification engine for news. Modern news sources may already be using AI or SEO practices to make articles more manipulative, bloated, clickbaity, or dishonest. The app can use AI and conventional compute in the opposite direction: stripping the article back down into useful information.</p>

<p>A useful metaphor from the conversation: it is like an end-to-end encoding pipeline where the transmitted data is not encrypted, just degraded into shit, and the local machine is trying to decompress it back into useful signal.</p>

<p>Another useful phrase: a bullshit codec. Lossless decompression for the internet.</p>

<h2>Important Design Instinct</h2>
<p>The owner wants to do as much preprocessing as possible with conventional compute instead of brute forcing everything with LLM calls. This is a key architectural instinct. LLMs should ideally be the expensive final editor or synthesizer, not the first-line sorter for every raw input.</p>

<h2>Classic Information Retrieval Direction</h2>
<p>The idea of counting word occurrences, removing common words, and comparing article word distributions is not a weird improvised neural network so much as classic information retrieval.</p>

<p>The core concept is <strong>TF-IDF</strong>:</p>
<ul>
  <li><strong>TF</strong>: term frequency, or how important a word is within a given article.</li>
  <li><strong>IDF</strong>: inverse document frequency, or how distinctive a word is across the whole corpus.</li>
  <li>Common words like articles, pronouns, and generic filler terms get removed or heavily downweighted.</li>
  <li>Distinctive repeated terms become strong signals for what an article is actually about.</li>
</ul>

<p>Once articles are represented as sparse vectors of weighted terms, they can be compared cheaply with cosine similarity. That gives a non-LLM way to cluster related articles, detect duplicates, or identify articles that are probably about the same event.</p>

<h2>Non-LLM Preprocessing Pipeline</h2>
<ol>
  <li>Normalize article text.</li>
  <li>Remove stopwords.</li>
  <li>Stem or lemmatize terms if useful.</li>
  <li>Extract named entities separately if possible.</li>
  <li>Compute TF-IDF over title plus body.</li>
  <li>Represent each article as a sparse vector.</li>
  <li>Compare article vectors with cosine similarity.</li>
  <li>Cluster articles above a similarity threshold.</li>
  <li>Use an LLM only after clustering, to summarize or synthesize the grouped articles.</li>
</ol>

<h2>N-Grams / Phrase Handling</h2>
<p>Single-word matching can work, but meaningful phrases are often much better. This points toward using n-grams.</p>

<p>Examples of useful phrase-level signals:</p>
<ul>
  <li>white house</li>
  <li>federal reserve</li>
  <li>interest rates</li>
  <li>rate cut</li>
  <li>school board</li>
  <li>supreme court</li>
</ul>

<p>Counting phrases can make clustering much smarter than counting isolated words alone.</p>

<h2>Named Entities</h2>
<p>Named entities should likely be extracted as their own signal layer. People, companies, government bodies, cities, agencies, teams, courts, bills, products, and organizations can provide high-value clues for grouping articles.</p>

<p>Named entities may also help distinguish articles that share generic topical vocabulary but are not actually about the same event.</p>

<h2>Harder Future Shape</h2>
<p>The tier 2 aggregation layer is less like “subscribe to feed, summarize article” and more like:</p>

<pre>discover → classify → extract claims → dedupe → cluster by event → merge details → preserve provenance → synthesize</pre>

<p>This is the likely shape of the real engine behind the app.</p>

<h2>Potential Output Goal</h2>
<p>The highest-value output may be a synthesized event article that is the union of useful details across many sources. The app should ideally be able to say:</p>
<ul>
  <li>Here is the actual event.</li>
  <li>Here are the facts all sources agree on.</li>
  <li>Here are the extra details each source adds.</li>
  <li>Here is what is still uncertain or source-dependent.</li>
  <li>Here is where each important detail came from.</li>
</ul>

<h2>Architectural North Star</h2>
<p>The LLM should not be the whole system. The more durable architecture is conventional information retrieval and clustering first, followed by LLM synthesis only after the app has already narrowed the problem into coherent event clusters.</p>

<p>A rough summary:</p>

<pre>TF-IDF + n-grams + cosine similarity + named entities → article/event clusters → LLM synthesis with provenance</pre>

<h2>Open Questions For Traversal</h2>
<ul>
  <li>How should tier 2 sources be discovered and classified?</li>
  <li>What counts as a source worth ingesting?</li>
  <li>How should the app distinguish duplicate coverage from related-but-different events?</li>
  <li>What non-LLM entity extraction options are good enough?</li>
  <li>How much clustering can be done with TF-IDF before embeddings become necessary?</li>
  <li>When should the app use embeddings instead of or in addition to TF-IDF?</li>
  <li>How should provenance be stored so generated summaries can cite their component facts?</li>
  <li>How should uncertainty and disagreement between sources be represented?</li>
  <li>What should the user-facing output look like: article, briefing, timeline, fact table, or all of the above?</li>
</ul>
