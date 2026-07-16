defmodule Newspaper.Extraction do
  alias Newspaper.Content
  alias Newspaper.Content.Article
  alias Newspaper.Operations
  alias Newspaper.Processing
  alias Newspaper.Processing.Registry
  alias Newspaper.Publishing

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

  defp do_execute_attempt(attempt) do
    {:ok, attempt} = Processing.mark_attempt_running(attempt)
    article = attempt.article
    {:ok, article} = Content.set_extraction_status(article, "running")
    url = article.resolved_url || article.canonical_url

    {:ok, run} =
      Operations.start_run("pipeline_step", "pipeline", %{
        "pipeline_step_attempt_id" => attempt.id,
        "pipeline_step_id" => attempt.pipeline_step_id,
        "article_id" => article.id,
        "url" => url
      })

    with {:ok, policy} <- Content.get_site_extraction_policy_for_url(url),
         {:ok, policy} <- Content.mark_site_extraction_attempted(policy),
         {:ok, {result, input_snapshot}} <-
           run_implementation_chain(url, article, policy, attempt) do
      finish_result(run, attempt, article, policy, result, input_snapshot)
    else
      {:error, reason} ->
        fail_execution(attempt, inspect(reason), "execution_error", run)
    end
  end

  defp run_implementation_chain(url, article, policy, attempt) do
    candidates =
      Registry.extraction_candidates(
        attempt.implementation_key,
        policy.minimum_implementation
      )

    candidates
    |> Enum.with_index()
    |> Enum.reduce_while({:error, :no_available_implementation}, fn
      {implementation_key, index}, _result ->
        implementation = Registry.fetch!(implementation_key)

        {result, input_snapshot, started_at, finished_at} =
          run_implementation(implementation, url, article, policy, attempt)

        case record_worker_attempt(
               article,
               policy,
               attempt,
               result,
               input_snapshot,
               started_at,
               finished_at
             ) do
          {:ok, _worker_attempt} ->
            more_candidates? = index < length(candidates) - 1

            if escalate?(policy, result) and more_candidates? do
              {:cont, {:ok, {result, input_snapshot}}}
            else
              {:halt, {:ok, {result, input_snapshot}}}
            end

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
    end)
  end

  defp run_implementation(implementation, url, article, policy, attempt) do
    config = attempt.pipeline_step.config
    started_at = DateTime.utc_now(:second)

    metadata = %{
      "article_id" => article.id,
      "pipeline_step_attempt_id" => attempt.id,
      "site_host" => policy.site_host
    }

    opts = [
      metadata: metadata,
      timeout_ms: config["timeout_ms"],
      minimum_text_length: config["minimum_text_length"]
    ]

    {result, input_snapshot} =
      case implementation.runtime.extract(url, opts) do
        {:ok, result, input_snapshot} -> {result, input_snapshot}
        {:error, result, input_snapshot} -> {result, input_snapshot}
      end

    finished_at = DateTime.utc_now(:second)
    {result, input_snapshot, started_at, finished_at}
  end

  defp escalate?(%{escalation_enabled: true}, result) do
    result["failure_kind"] in [
      "javascript_required",
      "auth_required",
      "paywall",
      "blocked",
      "insufficient_content"
    ]
  end

  defp escalate?(_policy, _result), do: false

  defp record_worker_attempt(
         article,
         policy,
         pipeline_attempt,
         result,
         input_snapshot,
         started_at,
         finished_at
       ) do
    Content.record_extraction_attempt(%{
      article_id: article.id,
      site_extraction_policy_id: policy.id,
      pipeline_step_attempt_id: pipeline_attempt.id,
      implementation: result["implementation"] || pipeline_attempt.implementation_key,
      status: result["status"] || "failed",
      failure_kind: result["failure_kind"],
      retryable: result["retryable"] || false,
      message: result["message"],
      final_url: result["final_url"],
      quality: result["quality"] || %{},
      input_snapshot: input_snapshot,
      output_snapshot: result,
      debug_metadata: result["debug_metadata"] || %{},
      started_at: started_at,
      finished_at: finished_at
    })
  end

  defp finish_result(run, attempt, article, policy, %{"status" => "ok"} = result, input) do
    with {:ok, {_article, _policy}} <-
           Content.record_extraction_success(article, policy, attempt.id, result),
         :ok <- rerender_article_items(article),
         {:ok, attempt} <-
           Processing.finish_attempt(attempt, "succeeded", %{
             input_snapshot: input,
             output_snapshot: result,
             debug_metadata: result["debug_metadata"] || %{}
           }),
         {:ok, _run} <-
           Operations.finish_run(run, "succeeded", %{
             summary_counts: %{"attempts" => 1, "succeeded" => 1, "failed" => 0}
           }) do
      {:ok, attempt}
    else
      {:error, reason} ->
        fail_execution(attempt, inspect(reason), "persistence_or_render_error", run)
    end
  end

  defp finish_result(run, attempt, article, policy, result, input) do
    with {:ok, {_article, _policy}} <- Content.record_extraction_failure(article, policy, result),
         {:ok, attempt} <-
           Processing.finish_attempt(attempt, "failed", %{
             failure_kind: result["failure_kind"],
             retryable: result["retryable"] || false,
             error_message: result["message"],
             input_snapshot: input,
             output_snapshot: result,
             debug_metadata: result["debug_metadata"] || %{}
           }) do
      create_failure(run, attempt, result["failure_kind"], result["message"], result["retryable"])

      Operations.finish_run(run, "failed", %{
        summary_counts: %{"attempts" => 1, "succeeded" => 0, "failed" => 1},
        error_summary: result["message"]
      })

      {:ok, attempt}
    else
      {:error, reason} ->
        fail_execution(attempt, inspect(reason), "persistence_error", run)
    end
  end

  defp fail_execution(attempt, message, failure_kind, run \\ nil) do
    attempt = Processing.get_attempt!(attempt.id)
    Content.set_extraction_status(attempt.article, "failed")

    result =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: failure_kind,
        retryable: true,
        error_message: message
      })

    create_failure(run, attempt, failure_kind, message, true)

    if run do
      Operations.finish_run(run, "failed", %{error_summary: message})
    end

    result
  end

  defp create_failure(run, attempt, failure_kind, message, retryable) do
    Operations.create_failure(%{
      failure_type: "pipeline_step_#{failure_kind || "failed"}",
      message: message || "Pipeline step failed",
      retryable: retryable || false,
      related: %{
        "pipeline_step_attempt_id" => attempt.id,
        "pipeline_step_id" => attempt.pipeline_step_id,
        "article_id" => attempt.article_id
      },
      run_id: run && run.id
    })
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
end
