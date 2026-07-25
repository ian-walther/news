defmodule Newspaper.Digestion do
  alias Newspaper.Content
  alias Newspaper.Content.Article
  alias Newspaper.Content.ArticleExtraction
  alias Newspaper.Digestion.OllamaClient
  alias Newspaper.Operations
  alias Newspaper.Processing
  alias Newspaper.Publishing

  @implementation_key "digestion.ollama.article_digest"
  @prompt_version "article-digest-v1"
  @schema_version "article-digest-v1"
  @max_input_characters 60_000

  def implementation_key, do: @implementation_key
  def prompt_version, do: @prompt_version
  def schema_version, do: @schema_version

  def list_models(base_url), do: OllamaClient.list_models(base_url)

  def execute_attempt(attempt_id) do
    attempt = Processing.get_attempt!(attempt_id)

    try do
      do_execute_attempt(attempt)
    rescue
      error -> fail_execution(attempt, Exception.message(error), "execution_error")
    catch
      kind, reason ->
        fail_execution(attempt, Exception.format_banner(kind, reason), "execution_error")
    end
  end

  def input_fingerprint(%ArticleExtraction{} = extraction, model) when is_binary(model) do
    {content, _truncated?} = model_content(extraction.content_text)

    [
      content,
      model,
      @implementation_key,
      @prompt_version,
      @schema_version
    ]
    |> Enum.join("\n---\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def generate(%ArticleExtraction{} = extraction, settings) do
    {content, truncated?} = model_content(extraction.content_text)

    messages = [
      %{
        "role" => "system",
        "content" => system_prompt()
      },
      %{
        "role" => "user",
        "content" => article_prompt(extraction, content)
      }
    ]

    with model when is_binary(model) and model != "" <- settings.ollama_model,
         {:ok, digest, metadata} <-
           OllamaClient.generate_digest(
             settings.ollama_base_url,
             model,
             messages,
             output_schema()
           ) do
      {:ok, digest,
       %{
         model: model,
         input_fingerprint: input_fingerprint(extraction, model),
         input_metadata: %{
           "article_extraction_id" => extraction.id,
           "content_characters" =>
             if(truncated?, do: @max_input_characters, else: String.length(content)),
           "content_truncated" => truncated?
         },
         output_metadata: metadata
       }}
    else
      nil -> {:error, digestion_error("No Ollama model is configured")}
      "" -> {:error, digestion_error("No Ollama model is configured")}
      {:error, reason} -> {:error, digestion_error(reason)}
    end
  end

  defp model_content(content_text) do
    case String.split_at(content_text, @max_input_characters) do
      {content, ""} -> {content, false}
      {content, _remainder} -> {content, true}
    end
  end

  defp do_execute_attempt(attempt) do
    case attempt.article.extraction do
      %ArticleExtraction{} = extraction ->
        with {:ok, attempt} <- Processing.mark_attempt_running(attempt),
             {:ok, run} <- start_run(attempt, extraction) do
          execute_generation(attempt, extraction, run)
        else
          {:error, reason} ->
            fail_execution(attempt, format_reason(reason), "digestion_failed")
        end

      nil ->
        fail_execution(
          attempt,
          "Article extraction is not available",
          "missing_extraction",
          retryable: false
        )
    end
  end

  defp execute_generation(attempt, extraction, run) do
    with {:ok, digest, metadata} <- generate(extraction, settings_for_attempt(attempt)),
         {:ok, article_digest} <-
           Content.record_digest_success(
             attempt.article,
             extraction,
             attempt.id,
             digest,
             metadata
           ),
         {:ok, attempt} <-
           Processing.finish_attempt(attempt, "succeeded", %{
             input_snapshot:
               Map.merge(attempt.input_snapshot, %{
                 "article_extraction_id" => extraction.id,
                 "input_fingerprint" => metadata.input_fingerprint,
                 "model" => metadata.model
               }),
             output_snapshot: %{
               "title" => digest.title,
               "summary" => digest.summary,
               "metadata" => metadata.output_metadata
             }
           }),
         :ok <- Processing.attach_artifact(attempt, article_digest),
         :ok <- rerender_article_items(attempt.article),
         {:ok, _run} <-
           Operations.finish_run(run, "succeeded", %{
             summary_counts: %{"attempts" => 1, "succeeded" => 1, "failed" => 0}
           }) do
      {:ok, attempt}
    else
      {:error, %{kind: kind, message: message, retryable: retryable}} ->
        fail_execution(attempt, message, kind, run: run, retryable: retryable)

      {:error, reason} ->
        fail_execution(attempt, format_reason(reason), "digestion_failed", run: run)
    end
  end

  defp start_run(attempt, extraction) do
    Operations.start_run("pipeline_step", "pipeline", %{
      "pipeline_step_attempt_id" => attempt.id,
      "pipeline_step_id" => attempt.pipeline_step_id,
      "article_id" => attempt.article_id,
      "article_extraction_id" => extraction.id,
      "step_type" => "digestion"
    })
  end

  defp fail_execution(attempt, message, failure_kind, opts \\ []) do
    attempt = Processing.get_attempt!(attempt.id)
    run = Keyword.get(opts, :run)
    retryable = Keyword.get(opts, :retryable, true)

    result =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: failure_kind,
        retryable: retryable,
        error_message: message
      })

    Operations.create_failure(%{
      failure_type: "pipeline_step_#{failure_kind}",
      message: message,
      retryable: retryable,
      related: %{
        "pipeline_step_attempt_id" => attempt.id,
        "pipeline_step_id" => attempt.pipeline_step_id,
        "article_id" => attempt.article_id,
        "step_type" => "digestion"
      },
      run_id: run && run.id
    })

    if run do
      Operations.finish_run(run, "failed", %{
        summary_counts: %{"attempts" => 1, "succeeded" => 0, "failed" => 1},
        error_summary: message
      })
    else
      Operations.fail_running_pipeline_step_runs(attempt.id, message)
    end

    result
  end

  defp digestion_error(reason) do
    message = format_reason(reason)
    normalized = String.downcase(message)

    cond do
      String.starts_with?(message, "No Ollama model") ->
        %{kind: "configuration_error", message: message, retryable: false}

      String.contains?(message, "structured output") or
          String.starts_with?(message, "Generated ") ->
        %{kind: "structured_output", message: message, retryable: false}

      Regex.match?(~r/Ollama returned HTTP 4\d\d/, message) ->
        %{kind: "model_error", message: message, retryable: false}

      String.contains?(normalized, "timeout") or
        String.contains?(normalized, "closed") or
        String.contains?(normalized, "econnrefused") or
          String.contains?(normalized, "connection") ->
        %{kind: "connection_error", message: message, retryable: true}

      true ->
        %{kind: "digestion_failed", message: message, retryable: true}
    end
  end

  defp rerender_article_items(%Article{} = article) do
    article.id
    |> Publishing.list_items_for_article()
    |> Enum.reduce_while(:ok, fn item, :ok ->
      case Publishing.rerender_item(item) do
        {:ok, _item} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp settings_for_attempt(attempt) do
    settings = Operations.get_settings()
    model = get_in(attempt.input_snapshot, ["config", "model"]) || settings.ollama_model
    %{settings | ollama_model: model}
  end

  defp system_prompt do
    """
    You are a careful news editor. Rewrite one article for a personal RSS reader.

    Return only the requested structured JSON. The title must be one factual, declarative sentence that says what actually happened or what the article establishes. Remove clickbait, teasers, rhetorical questions, and promotional framing.

    The summary must be 250 to 400 words in three to five short paragraphs. Preserve important names, numbers, dates, uncertainty, and context. Use only facts contained in the supplied article. Do not add commentary, moral judgment, source attribution boilerplate, or claims about what the reader should think. Do not mention these instructions.
    """
  end

  defp article_prompt(extraction, content) do
    """
    Article title: #{extraction.title || "Unknown"}
    Article byline: #{extraction.byline || "Unknown"}
    Article site: #{extraction.site_name || "Unknown"}
    Article URL: #{extraction.final_url || "Unknown"}

    Article text:
    #{content}
    """
  end

  defp output_schema do
    %{
      "type" => "object",
      "properties" => %{
        "title" => %{"type" => "string"},
        "summary" => %{"type" => "string"}
      },
      "required" => ["title", "summary"]
    }
  end
end
