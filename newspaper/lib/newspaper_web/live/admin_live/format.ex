defmodule NewspaperWeb.AdminLive.Format do
  @moduledoc false

  def run_type_label("pipeline_batch"), do: "Pipeline batch"
  def run_type_label("fetch_all"), do: "Feed refresh"
  def run_type_label("fetch_input_feed"), do: "Feed fetch"
  def run_type_label("process_input_feed"), do: "Feed processing"
  def run_type_label("process_intake_group"), do: "Group processing"
  def run_type_label("backfill_output_feed"), do: "Add matching articles"
  def run_type_label("rerender_output_feed"), do: "Refresh RSS output"
  def run_type_label("pipeline_step"), do: "Pipeline attempt"
  def run_type_label(value), do: humanize(value)

  def run_subject(entry) do
    entry.generated_feed_title ||
      entry.input_feed_name ||
      fallback_run_subject(entry.run)
  end

  def run_summary(%{run: run}), do: run_summary(run)

  def run_summary(%{run_type: "pipeline_batch", summary_counts: counts}) do
    if Map.has_key?(counts || %{}, "total") do
      [
        count_phrase(counts, "succeeded", "succeeded"),
        count_phrase(counts, "failed", "failed"),
        count_phrase(counts, "skipped", "skipped"),
        count_phrase(counts, "cancelled", "cancelled"),
        count_phrase(counts, "queued", "queued"),
        count_phrase(counts, "running", "running")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")
      |> empty_fallback("Nothing to do")
    else
      "Waiting to start"
    end
  end

  def run_summary(%{run_type: "fetch_all", summary_counts: counts}) do
    "#{count(counts, "ok")} feeds succeeded · #{count(counts, "error")} failed"
  end

  def run_summary(%{run_type: "fetch_input_feed", summary_counts: counts}) do
    "Fetched #{count(counts, "items")} items"
  end

  def run_summary(%{run_type: run_type, summary_counts: counts})
      when run_type in ["process_input_feed", "process_intake_group"] do
    "#{count(counts, "articles_seen")} articles from #{count(counts, "raw_items")} feed items"
  end

  def run_summary(%{run_type: "backfill_output_feed", summary_counts: counts}) do
    "#{count(counts, "items_created")} added · #{count(counts, "items_existing")} already present"
  end

  def run_summary(%{run_type: "rerender_output_feed", summary_counts: counts}) do
    "#{count(counts, "items_rendered")} rendered · #{count(counts, "items_failed")} failed"
  end

  def run_summary(%{summary_counts: counts}) when map_size(counts) == 0,
    do: "No summary available"

  def run_summary(%{summary_counts: counts}) do
    counts
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(" · ", fn {key, value} ->
      "#{value} #{humanize(key) |> String.downcase()}"
    end)
  end

  @doc """
  One line for a batch: `done of total`, then a rate and rounded estimate
  when `Processing.batch_progress/2` found one defensible, otherwise the
  reason there is none.
  """
  def progress_summary(%{eta_reason: :not_started}), do: "Waiting to start"

  def progress_summary(%{done: done, total: total} = progress) do
    [
      "#{done} of #{total}",
      progress_detail(progress)
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp progress_detail(%{eta_reason: :complete}), do: nil
  defp progress_detail(%{eta_reason: :paused}), do: "paused"
  defp progress_detail(%{eta_reason: :site_backoff}), do: "waiting on site backoff"
  defp progress_detail(%{eta_reason: :insufficient_samples}), do: "estimating"

  defp progress_detail(%{per_minute: per_minute, eta_seconds: eta_seconds})
       when is_number(per_minute) and is_integer(eta_seconds) do
    "#{format_rate(per_minute)}/min · ~#{eta_label(eta_seconds)} left"
  end

  defp progress_detail(_progress), do: nil

  @doc "Executions completed per minute for a stage, or why there is no rate yet."
  def throughput_label(%{per_minute: nil, window_minutes: minutes}),
    do: "No rate yet (fewer than 3 completions in #{minutes} min)"

  def throughput_label(%{per_minute: per_minute, window_minutes: minutes}),
    do: "#{format_rate(per_minute)}/min over #{minutes} min"

  @doc """
  A stage's queue line: queued count, rate, and an estimate only when the
  stage is moving and not paused.
  """
  def stage_eta_label(%{queued: 0}), do: nil
  def stage_eta_label(%{paused: true}), do: "paused"
  def stage_eta_label(%{backoff: true}), do: "held by website backoff"
  def stage_eta_label(%{per_minute: nil}), do: "estimating"

  def stage_eta_label(%{queued: queued, per_minute: per_minute}),
    do: "~#{eta_label(round(queued / per_minute * 60))} left"

  def batch_selection_label("failed"), do: "Failed items"
  def batch_selection_label("items"), do: "Selected items"
  def batch_selection_label(_selection), do: "Existing items"

  def format_rate(per_minute) when per_minute >= 10, do: Integer.to_string(round(per_minute))
  def format_rate(per_minute), do: :erlang.float_to_binary(per_minute / 1, decimals: 1)

  defp eta_label(seconds) when seconds < 90, do: "1 min"
  defp eta_label(seconds) when seconds < 3_600, do: "#{round(seconds / 60)} min"

  defp eta_label(seconds) when seconds < 36_000,
    do: "#{:erlang.float_to_binary(seconds / 3_600, decimals: 1)} h"

  defp eta_label(seconds), do: "#{round(seconds / 3_600)} h"

  @doc "Coverage for one step of one feed, in output item steps."
  def coverage_label(counts) do
    [
      "#{counts.ready} of #{counts.total} ready",
      count_phrase(counts, :queued, "queued"),
      count_phrase(counts, :running, "running"),
      count_phrase(counts, :blocked, "waiting"),
      count_phrase(counts, :pending, "requested"),
      count_phrase(counts, :not_requested, "not requested"),
      count_phrase(counts, :failed, "failed"),
      count_phrase(counts, :skipped, "skipped"),
      count_phrase(counts, :cancelled, "cancelled")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "Operator-facing text for a `Newspaper.Processing` error reason."
  def processing_error_message({:no_enabled_step, step_type}),
    do: "Enable #{step_type} for this feed first"

  def processing_error_message(:extraction_step_required), do: "Enable article extraction first"

  def processing_error_message({:prerequisite_required, step_type}),
    do: "Enable #{step_type} first"

  def processing_error_message(:ollama_model_not_configured),
    do: "Choose an Ollama model in Settings first"

  def processing_error_message(:digest_rendering_requires_digestion),
    do: "Digest title or summary requires article digestion"

  def processing_error_message(:digestion_requires_extraction),
    do: "Disable article digestion before disabling extraction"

  def processing_error_message({:dependent_step_enabled, step_type}),
    do: "Disable #{step_type} first"

  def processing_error_message(:rendering_requires_extraction),
    do: "Hosted links or extracted bodies require article extraction"

  def processing_error_message({:rendering_depends_on_step, step_type}),
    do: "This feed's rendering settings depend on #{step_type}"

  def processing_error_message(:step_exists), do: "This feed already has that step"
  def processing_error_message(:batch_cancelled), do: "That batch was cancelled"

  def processing_error_message(:batch_already_running),
    do: "A batch for this step is already running"

  def processing_error_message(:digestion_paused), do: "Digestion is paused"
  def processing_error_message(:no_eligible_items), do: "None of those items can be processed"
  def processing_error_message({:close_run, :not_found}), do: "That run no longer exists"

  def processing_error_message({:close_run, :not_closable}),
    do: "Only operations can be closed this way"

  def processing_error_message({:close_run, :not_running}), do: "That run already finished"

  def processing_error_message({:close_run, :within_timeout}),
    do: "That run is still within its expected time"

  def processing_error_message({:close_run, :owner_alive}),
    do: "That run's owner is still alive; it is slow, not abandoned"

  def processing_error_message(:step_has_active_work),
    do: "Wait for queued and running work on this step to finish first"

  def processing_error_message({:unknown_step_type, step_type}),
    do: "#{step_type} is not a registered step"

  def processing_error_message({:invalid_batch_selection, _selection}),
    do: "Choose which items the batch should include"

  def processing_error_message(%Ecto.Changeset{}), do: "Processing setting could not be saved"
  def processing_error_message(reason), do: inspect(reason)

  def failure_type_label("pipeline_step_rate_limited"), do: "Rate limited"
  def failure_type_label("fetch_input_feed_failed"), do: "Feed fetch failed"
  def failure_type_label("pipeline_step_timeout"), do: "Extraction timed out"
  def failure_type_label("pipeline_step_http_error"), do: "Article request failed"
  def failure_type_label("pipeline_step_not_found"), do: "Article not found"
  def failure_type_label(value), do: humanize(value)

  def status_label(value), do: humanize(value)

  @doc """
  The shared vocabulary for pipeline work (item steps, attempts, article
  extraction state). Runs keep `status_label/1`.
  """
  def work_status_label("not_requested"), do: "Not requested"
  def work_status_label(status) when status in ["pending", "blocked"], do: "Waiting"
  def work_status_label("queued"), do: "Queued"
  def work_status_label("running"), do: "Running"
  def work_status_label("succeeded"), do: "Ready"
  def work_status_label("failed"), do: "Failed"
  def work_status_label("skipped"), do: "Skipped"
  def work_status_label("cancelled"), do: "Cancelled"
  def work_status_label(value), do: humanize(value)

  def work_status_badge_class("succeeded"), do: "badge badge-success badge-soft"
  def work_status_badge_class("failed"), do: "badge badge-error badge-soft"
  def work_status_badge_class("running"), do: "badge badge-info badge-soft"
  def work_status_badge_class("queued"), do: "badge badge-warning badge-soft"
  def work_status_badge_class("cancelled"), do: "badge badge-neutral badge-soft"
  def work_status_badge_class(_status), do: "badge badge-ghost"

  def status_badge_class("succeeded"), do: "badge badge-success badge-soft"
  def status_badge_class("failed"), do: "badge badge-error badge-soft"
  def status_badge_class("running"), do: "badge badge-info badge-soft"
  def status_badge_class("queued"), do: "badge badge-warning badge-soft"
  def status_badge_class(_status), do: "badge badge-ghost"

  def parse_id(value) when is_integer(value) and value > 0, do: value

  def parse_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  def parse_id(_value), do: nil

  def article_host(url), do: url_host(url) || "Unknown source"

  def url_host(nil), do: nil

  def url_host(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
    |> case do
      nil -> nil
      host -> String.trim_leading(host, "www.")
    end
  rescue
    _ -> nil
  end

  def blank?(value), do: value in [nil, ""]
  def present?(value), do: is_binary(value) and String.trim(value) != ""

  def duration(%{started_at: nil}), do: "Duration unavailable"

  def duration(%{started_at: started_at, finished_at: finished_at}) do
    finished_at = finished_at || DateTime.utc_now()
    seconds = max(DateTime.diff(finished_at, started_at, :second), 0)

    cond do
      seconds < 60 -> "#{seconds}s"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      true -> "#{div(seconds, 3_600)}h #{div(rem(seconds, 3_600), 60)}m"
    end
  end

  defp fallback_run_subject(%{run_type: "fetch_all"}), do: "All input feeds"

  defp fallback_run_subject(run) do
    run.related["url"]
    |> url_host()
    |> case do
      nil -> "Newspaper"
      host -> host
    end
  end

  defp count_phrase(counts, key, label) do
    value = if is_atom(key), do: Map.get(counts, key, 0), else: count(counts, key)
    if value > 0, do: "#{value} #{label}"
  end

  defp count(counts, key), do: Map.get(counts || %{}, key, 0)

  defp empty_fallback("", fallback), do: fallback
  defp empty_fallback(value, _fallback), do: value

  defp humanize(nil), do: "Unknown"

  defp humanize(value) do
    value
    |> to_string()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
