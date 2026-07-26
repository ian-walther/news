<h2>Purpose</h2>
<p>This note captures the research and systems lineage behind the newspaper app idea. The goal is not to create a formal literature review yet, but to preserve the conceptual map that emerged from the conversation: this project is adjacent to classic information retrieval, early web search, document clustering, entity extraction, media monitoring, and modern LLM synthesis.</p>

<h2>Core Framing</h2>
<p>The app is not just an RSS reader and not just an AI summarizer. It is closer to a personal information retrieval and event reconstruction system.</p>

<p>The key architectural instinct is to use conventional compute to organize the problem before using an LLM. The LLM should ideally synthesize already-structured evidence rather than act as the first and only reasoning layer over raw article sludge.</p>

<h2>Classic Information Retrieval</h2>
<p>The immediate technical lineage is classic information retrieval. This includes representing documents as bags of words, weighted vectors, inverted indexes, and ranked matches.</p>

<p>Important concepts:</p>
<ul>
  <li><strong>Tokenization:</strong> splitting article text into searchable/indexable units.</li>
  <li><strong>Stopword removal:</strong> removing or downweighting common words that carry little topic signal.</li>
  <li><strong>Stemming / lemmatization:</strong> reducing related word forms to a shared base form when useful.</li>
  <li><strong>Inverted index:</strong> mapping terms to the documents that contain them, which is the classic backbone of search engines.</li>
  <li><strong>TF-IDF:</strong> weighting terms by how important they are in one document and how distinctive they are across the corpus.</li>
  <li><strong>BM25:</strong> a stronger classic ranking function descended from probabilistic information retrieval, often better than naive TF-IDF for search.</li>
  <li><strong>Vector-space model:</strong> representing documents as weighted term vectors.</li>
  <li><strong>Cosine similarity:</strong> comparing document vectors to estimate how similar two articles are.</li>
</ul>

<h2>Early Google Lineage</h2>
<p>There is a meaningful connection to early Google-era thinking, but with an important distinction.</p>

<p>Early Google was primarily solving retrieval and ranking:</p>

<pre>crawl web → parse documents and links → build index → rank pages using text signals plus link structure</pre>

<p>The famous early Google insight was that the structure around documents mattered. PageRank used link structure as a signal of importance. Anchor text, titles, URLs, proximity, and other document/context signals helped rank results.</p>

<p>The newspaper app can borrow the general lesson: useful signals are not limited to article text. The context around an article matters too.</p>

<p>Potential analogs:</p>
<ul>
  <li>A major national outlet may be high-authority but low-detail.</li>
  <li>A local article may be low-authority globally but high-detail for a specific event.</li>
  <li>A press release may have strong provenance but biased framing.</li>
  <li>A repeated fact across many sources may deserve higher confidence.</li>
  <li>A unique fact from one source may be valuable but should retain provenance.</li>
  <li>Source reputation, source type, publication time, article freshness, citation/link relationships, and named entities can all become ranking or confidence signals.</li>
</ul>

<h2>How This Differs From Search</h2>
<p>The app is not primarily trying to answer a search query with a ranked list of documents.</p>

<p>It is trying to reconstruct useful reality from a stream of overlapping, degraded, partial, duplicated, or manipulative articles.</p>

<p>Search problem:</p>
<pre>query → ranked documents</pre>

<p>Newspaper app problem:</p>
<pre>article stream → event clusters → extracted claims → provenance → synthesized account</pre>

<p>This makes the project closer to event detection and event reconstruction than classic search alone.</p>

<h2>Document Clustering</h2>
<p>Document clustering is the bridge between RSS ingestion and event synthesis.</p>

<p>Basic flow:</p>
<ol>
  <li>Represent each article as a vector.</li>
  <li>Compare articles using a similarity metric.</li>
  <li>Group articles that are likely about the same event.</li>
  <li>Separate articles that share general topics but are not the same event.</li>
  <li>Feed each coherent cluster into later stages.</li>
</ol>

<p>Candidate signals for clustering:</p>
<ul>
  <li>TF-IDF or BM25 terms</li>
  <li>n-grams and key phrases</li>
  <li>named entities</li>
  <li>dates and timestamps</li>
  <li>locations</li>
  <li>source type</li>
  <li>title similarity</li>
  <li>article body similarity</li>
  <li>semantic embeddings, if classic methods are insufficient</li>
</ul>

<h2>N-Grams And Phrases</h2>
<p>Single words are useful, but phrases often carry far more meaning.</p>

<p>Examples:</p>
<ul>
  <li>federal reserve</li>
  <li>interest rate</li>
  <li>rate cut</li>
  <li>white house</li>
  <li>supreme court</li>
  <li>school board</li>
</ul>

<p>N-grams help avoid losing meaning when important concepts are multi-word phrases.</p>

<h2>Named Entities</h2>
<p>Named entities should likely be treated as a separate signal layer rather than just ordinary words.</p>

<p>Useful entity types:</p>
<ul>
  <li>people</li>
  <li>companies</li>
  <li>government agencies</li>
  <li>courts</li>
  <li>cities and regions</li>
  <li>countries</li>
  <li>sports teams</li>
  <li>products</li>
  <li>bills, laws, policies, or named programs</li>
</ul>

<p>Named entities can help distinguish articles that use similar topical vocabulary but are about different underlying events.</p>

<h2>Event Detection And Reconstruction</h2>
<p>The deeper lineage is event detection: identifying when multiple documents in a stream refer to the same thing happening in the world.</p>

<p>The newspaper app should eventually reason in terms of events, not just articles.</p>

<p>Possible event object fields:</p>
<ul>
  <li>event title</li>
  <li>event summary</li>
  <li>time window</li>
  <li>location</li>
  <li>entities involved</li>
  <li>source articles</li>
  <li>agreed facts</li>
  <li>unique details</li>
  <li>conflicting claims</li>
  <li>open questions</li>
  <li>provenance links for important claims</li>
</ul>

<h2>Provenance As A First-Class Concern</h2>
<p>Provenance is one of the key differences between a useful information engine and AI slop.</p>

<p>The app should preserve where details came from, especially when synthesizing across sources. A generated article should not be a magical answer with no source trail. It should be able to support claims with references back to the source articles or extracted claim records.</p>

<p>Important distinction:</p>
<ul>
  <li>The app can synthesize prose with an LLM.</li>
  <li>But the factual substrate should be traceable.</li>
</ul>

<h2>Uncertainty And Disagreement</h2>
<p>Normal summaries often flatten uncertainty. This project should preserve uncertainty when sources disagree or when information is only weakly supported.</p>

<p>Useful categories:</p>
<ul>
  <li>facts reported by all or most sources</li>
  <li>facts reported by one source only</li>
  <li>claims from official sources</li>
  <li>claims from interested parties</li>
  <li>details that conflict between sources</li>
  <li>details that changed over time</li>
  <li>facts that are plausible but not yet well-supported</li>
</ul>

<h2>Academic And Commercial Relatives</h2>
<p>The project is related to systems used in research, media analysis, finance, public relations, OSINT, crisis monitoring, and institutional news intelligence.</p>

<p>Relevant adjacent categories:</p>
<ul>
  <li>media monitoring</li>
  <li>event detection</li>
  <li>topic detection and tracking</li>
  <li>document clustering</li>
  <li>claim extraction</li>
  <li>knowledge graph construction</li>
  <li>source credibility modeling</li>
  <li>news summarization</li>
</ul>

<p>Examples of adjacent worlds include GDELT, Media Cloud, commercial media intelligence tools, financial-news systems, PR monitoring systems, and academic event-detection work.</p>

<h2>Open-Source Gap</h2>
<p>The likely gap is not that nobody has solved the pieces. The gap is that there does not appear to be a mature, open-source, self-hosted, everyday-person tool that combines the pieces into a personal newspaper/intelligence engine.</p>

<p>Most open-source personal news tools appear to live closer to:</p>

<pre>RSS reader + article summaries</pre>

<p>This project is aiming closer to:</p>

<pre>source ingestion + retrieval + clustering + event modeling + provenance + synthesis</pre>

<h2>Near-Term Conceptual Prototype</h2>
<p>A useful first prototype should probably stay humble and prove the core loop before trying to solve the whole problem.</p>

<pre>existing RSS article corpus → TF-IDF/BM25 vectors → similarity scoring → article clusters → LLM cluster summary</pre>

<p>That prototype would answer the first important question: can the app identify related articles and form useful clusters without using an LLM for every judgment?</p>

<h2>Longer-Term Pipeline</h2>
<pre>discover → classify → extract claims → dedupe → cluster by event → merge details → preserve provenance → synthesize</pre>

<p>This remains the high-level research path.</p>

<h2>Key Research Questions</h2>
<ul>
  <li>How far can TF-IDF/BM25 and n-grams get before embeddings are needed?</li>
  <li>What is the right threshold for article similarity?</li>
  <li>How should event clusters merge, split, and age out over time?</li>
  <li>How should a system distinguish one continuing story from several related events?</li>
  <li>What should count as a claim?</li>
  <li>Should claims be extracted with rules, local models, or larger LLMs?</li>
  <li>How should source type and source quality affect confidence?</li>
  <li>How should the system represent uncertainty in the generated output?</li>
  <li>What UI makes provenance visible without making the app feel like homework?</li>
</ul>

<h2>Working Mental Model</h2>
<p>The newspaper app should borrow from search engines, but it is not a search engine. It should borrow from media-intelligence systems, but it is not an institutional dashboard. It should use LLMs, but it should not be an LLM wrapper.</p>

<p>The durable mental model is:</p>

<pre>classic IR and clustering create structured evidence; LLMs turn structured evidence into readable synthesis; provenance keeps the synthesis honest.</pre>
