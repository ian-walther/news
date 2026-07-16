defmodule NewspaperWeb.AdminLive.Format do
  @moduledoc false

  def run_type_label("pipeline_batch"), do: "Extraction batch"
  def run_type_label("fetch_all"), do: "Feed refresh"
  def run_type_label("fetch_input_feed"), do: "Feed fetch"
  def run_type_label("process_input_feed"), do: "Feed processing"
  def run_type_label("process_intake_group"), do: "Group processing"
  def run_type_label("backfill_output_feed"), do: "Output backfill"
  def run_type_label("rerender_output_feed"), do: "Output re-render"
  def run_type_label("pipeline_step"), do: "Extraction attempt"
  def run_type_label(value), do: humanize(value)

  def run_subject(entry) do
    entry.generated_feed_title ||
      entry.input_feed_name ||
      fallback_run_subject(entry.run)
  end

  def run_summary(%{run: run}), do: run_summary(run)

  def run_summary(%{run_type: "pipeline_batch", summary_counts: counts}) do
    [
      count_phrase(counts, "succeeded", "succeeded"),
      count_phrase(counts, "failed", "failed"),
      count_phrase(counts, "skipped", "skipped")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> empty_fallback("Waiting to start")
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

  def failure_type_label("pipeline_step_rate_limited"), do: "Rate limited"
  def failure_type_label("fetch_input_feed_failed"), do: "Feed fetch failed"
  def failure_type_label("pipeline_step_timeout"), do: "Extraction timed out"
  def failure_type_label("pipeline_step_http_error"), do: "Article request failed"
  def failure_type_label("pipeline_step_not_found"), do: "Article not found"
  def failure_type_label(value), do: humanize(value)

  def status_label(value), do: humanize(value)

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
    value = count(counts, key)
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

  defp url_host(nil), do: nil

  defp url_host(url) do
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
end
