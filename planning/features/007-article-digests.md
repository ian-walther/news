# Article Digests

## Goal

Add one bounded local-LLM pipeline feature that turns a successfully extracted article into a factual replacement title and a useful reading summary.

The feature exists to make generated feeds easier to scan in FreshRSS and Reeder:

- replace clickbait or vague headlines with a plain declarative sentence about the article
- replace the article body with an appropriately sized summary when the output feed chooses that rendering mode

This is an article-level reading aid inside Newspaper. It should not become a general LLM platform or absorb future multi-source story synthesis, clustering, World Radar, or morning-newspaper planning.

## Pipeline Shape

Use one pipeline step type:

- step type: `digestion`
- initial implementation: `digestion.ollama.article_digest`

The step is configured on an output feed. Its durable result is scoped to the article and pipeline step because different outputs may intentionally select different models or later use different digest configuration.

```text
generated feed item
  -> successful durable article extraction
  -> enabled article-digest step
  -> Ollama structured generation
  -> validated title and summary artifact
  -> generated feed item render snapshot updated according to output settings
```

Digest generation must use durable extracted article text. It should not silently fall back to the raw RSS body when extraction is missing or failed.

Enabling the step applies to future generated feed items. Existing eligible items require an explicit `Digest existing articles` bulk action. Re-running successful items should require an explicit reprocess action rather than happening during ordinary backlog processing.

## Structured Result

The implementation should request and validate one structured response containing both values:

```json
{
  "title": "A factual single-sentence description of the article.",
  "summary": "A concise factual summary sized for reading in a feed client."
}
```

Initial output rules:

- `title` is nonempty, bounded in length, declarative, and one sentence.
- `title` states what the article is actually about rather than preserving clickbait framing.
- `summary` is nonempty, bounded in length, and grounded only in the extracted article.
- Output is plain text. The application owns escaping and feed-safe paragraph rendering.
- Invalid structured output is a visible, retryable pipeline failure; it is not published as partial content.

The app should store the structured result and enough request metadata to reproduce or explain it. It should not request or persist model chain-of-thought.

## Ollama Connection And Model Discovery

The Phoenix application should call Ollama directly over HTTP with `Req`. Ollama is already the external model runtime, so this feature does not need an additional wrapper executable.

Application settings should include a configurable Ollama base URL. The initial deployment value is:

```text
http://desktop.home:11434
```

The admin UI should discover installed models from Ollama's `/api/tags` endpoint and use the live result to populate model selection for an article-digest pipeline step.

Model-selection behavior:

- Persist the selected Ollama model name in the pipeline step config.
- Provide an explicit refresh-models action in the UI.
- Do not persist a separate model catalog initially; Ollama remains the source of truth for what is installed.
- If discovery is unavailable, preserve and display the saved model selection rather than clearing it.
- Surface connection and discovery errors with enough detail to distinguish an unreachable server from an unavailable selected model.
- Validate that a model is selected before enabling or running the step.

The first implementation does not need provider abstraction, capability negotiation, model installation, or model lifecycle management.

## Durable Artifact

Store a current `article_digests` artifact with at least:

- article ID
- pipeline step ID
- extraction ID or deterministic extraction input hash
- implementation key
- Ollama model name
- prompt/schema version
- step config snapshot
- generated title
- generated summary
- validation and useful debug metadata
- generated and updated timestamps

Pipeline attempts retain execution history and errors. The current digest artifact is the value used by deterministic output rendering.

Changing the selected model, prompt/schema version, or digest configuration should affect future work by default. Existing artifacts remain understandable from their stored metadata and are replaced only by an explicit bulk or individual re-digest action.

## Output Rendering

Digest rendering should extend output-feed source selection without changing item identity:

- title source: `original` or `digest`
- body source: `original_feed`, `extracted_content`, or `digest_summary`
- link source remains independently selectable as original article or hosted article

The generated feed item GUID must remain stable when a digest is produced, replaced, or selected for rendering.

The title and body choices are independent. An output may use a digest title with full extracted content, or use both the digest title and digest summary.

## Operator Experience

The output pipeline UI should let the operator:

- add and enable the article-digest step
- discover and select an installed Ollama model
- see whether the Ollama connection and selected model are available
- digest existing eligible articles explicitly
- see queued, processing, ready, and failed digest counts
- inspect the generated title, summary, model, input extraction, and attempt details
- retry a failed digest or explicitly regenerate a successful one

Digest failures should not be confused with extraction failures. Articles waiting on extraction should be shown as blocked or not yet eligible rather than as failed model work.

## Deliberate Non-Goals

- A provider-neutral LLM framework.
- A reusable prompt registry or prompt playground.
- Cross-article or cross-source synthesis.
- Story clustering or World Radar behavior.
- Morning-newspaper section generation.
- Automatic model installation or deletion.
- Sharing or deduplicating digest artifacts across differently configured output steps.
- Semantic filtering in the same implementation.

## Open Decisions Before Implementation

- When digest rendering is selected, should a new feed item wait for a successful digest, or publish original content immediately and re-render when the digest arrives?
- What summary length and paragraph shape are most useful in Reeder?
- What initial prompt and structured-output validation bounds produce consistently factual results?
- Which installed model should be the initial selection after representative article testing?
- What concurrency limit should Newspaper apply to Ollama work on `desktop.home`?
- Which model and schema failures should retry automatically, and which should wait for explicit operator retry?
