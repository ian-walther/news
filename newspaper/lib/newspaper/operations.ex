defmodule Newspaper.Operations do
  import Ecto.Query

  alias Newspaper.Content.Article
  alias Newspaper.Intake.InputFeed
  alias Newspaper.Operations.{AppSettings, Failure, Run}
  alias Newspaper.Publishing.GeneratedFeed
  alias Newspaper.Repo

  def get_settings do
    Repo.one(from s in AppSettings, order_by: [asc: s.id], limit: 1) ||
      create_default_settings!()
  end

  def update_settings(%AppSettings{} = settings, attrs) do
    settings
    |> AppSettings.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:settings_changed)
  end

  def change_settings(%AppSettings{} = settings, attrs \\ %{}) do
    AppSettings.changeset(settings, attrs)
  end

  def list_runs(limit \\ 50) do
    Run
    |> order_by([r], desc: r.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_run!(id), do: Repo.get!(Run, id)

  def latest_run(run_type) do
    Run
    |> where([run], run.run_type == ^run_type)
    |> order_by([run], desc: run.started_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  def list_run_entries(scope \\ "overview", status \\ "all", limit \\ 100) do
    Run
    |> run_scope(scope)
    |> run_status(status)
    |> order_by([run], desc: run.started_at, desc: run.id)
    |> limit(^limit)
    |> Repo.all()
    |> attach_run_context()
  end

  def start_run(run_type, trigger, related \\ %{}, debug_metadata \\ %{}) do
    %Run{}
    |> Run.changeset(%{
      run_type: run_type,
      trigger: trigger,
      status: "running",
      started_at: DateTime.utc_now(:second),
      related: related,
      debug_metadata: debug_metadata
    })
    |> Repo.insert()
    |> broadcast_on_ok(:operations_changed)
  end

  def finish_run(%Run{} = run, status, attrs \\ %{}) do
    attrs =
      attrs
      |> Map.put(:status, status)
      |> Map.put(:finished_at, DateTime.utc_now(:second))

    run
    |> Run.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:operations_changed)
  end

  def update_run(%Run{} = run, attrs) do
    run
    |> Run.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:operations_changed)
  end

  def list_failures(limit \\ 50) do
    Failure
    |> order_by([f], desc: f.inserted_at)
    |> limit(^limit)
    |> preload(:run)
    |> Repo.all()
  end

  def get_failure!(id) do
    Failure
    |> Repo.get!(id)
    |> Repo.preload(:run)
  end

  def create_failure(attrs) do
    %Failure{}
    |> Failure.changeset(attrs)
    |> Repo.insert()
    |> broadcast_on_ok(:operations_changed)
  end

  def increment_failure_retry(%Failure{} = failure) do
    failure
    |> Failure.changeset(%{
      retry_count: failure.retry_count + 1,
      last_attempted_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
    |> broadcast_on_ok(:operations_changed)
  end

  def list_actionable_failure_groups(limit \\ 8) do
    failures =
      Failure
      |> order_by([failure], desc: failure.inserted_at, desc: failure.id)
      |> limit(500)
      |> preload(:run)
      |> Repo.all()

    article_statuses = current_article_statuses(failures)
    input_feeds = current_input_feeds(failures)

    failures
    |> Enum.filter(&actionable_failure?(&1, article_statuses, input_feeds))
    |> Enum.group_by(&failure_group_key(&1, input_feeds))
    |> Enum.map(fn {{failure_type, source}, grouped_failures} ->
      latest = Enum.max_by(grouped_failures, &{&1.inserted_at, &1.id})

      latest_retryable =
        grouped_failures
        |> Enum.filter(& &1.retryable)
        |> Enum.max_by(&{&1.inserted_at, &1.id}, fn -> nil end)

      %{
        id: latest.id,
        failure_type: failure_type,
        source: source,
        count: length(grouped_failures),
        retryable_count: Enum.count(grouped_failures, & &1.retryable),
        latest_failure_id: latest_retryable && latest_retryable.id,
        latest_at: latest.inserted_at,
        message: latest.message,
        related: latest.related,
        run_related: (latest.run && latest.run.related) || %{}
      }
    end)
    |> Enum.sort_by(&{&1.latest_at, &1.id}, :desc)
    |> Enum.take(limit)
  end

  defp create_default_settings! do
    %AppSettings{}
    |> AppSettings.changeset(%{})
    |> Repo.insert!()
  end

  defp broadcast_on_ok({:ok, value}, event) do
    Newspaper.Events.broadcast_data_changed(event)
    {:ok, value}
  end

  defp broadcast_on_ok(result, _event), do: result

  defp run_scope(query, "all"), do: query

  defp run_scope(query, _overview) do
    overview_types = [
      "fetch_all",
      "backfill_output_feed",
      "rerender_output_feed",
      "pipeline_batch"
    ]

    where(
      query,
      [run],
      run.run_type in ^overview_types or
        (run.trigger not in ["system", "pipeline"] and run.run_type != "pipeline_step")
    )
  end

  defp run_status(query, status) when status in ["running", "succeeded", "failed"] do
    where(query, [run], run.status == ^status)
  end

  defp run_status(query, _status), do: query

  defp attach_run_context(runs) do
    input_feed_ids = related_ids(runs, "input_feed_id")
    generated_feed_ids = related_ids(runs, "generated_feed_id")

    input_feed_names =
      InputFeed
      |> where([feed], feed.id in ^input_feed_ids)
      |> select([feed], {feed.id, feed.name})
      |> Repo.all()
      |> Map.new()

    generated_feed_titles =
      GeneratedFeed
      |> where([feed], feed.id in ^generated_feed_ids)
      |> select([feed], {feed.id, feed.title})
      |> Repo.all()
      |> Map.new()

    Enum.map(runs, fn run ->
      input_feed_id = related_id(run.related, "input_feed_id")
      generated_feed_id = related_id(run.related, "generated_feed_id")

      %{
        id: run.id,
        run: run,
        input_feed_name: input_feed_names[input_feed_id],
        generated_feed_title:
          run.related["generated_feed_title"] || generated_feed_titles[generated_feed_id]
      }
    end)
  end

  defp related_ids(runs, key) do
    runs
    |> Enum.map(&related_id(&1.related, key))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp current_article_statuses(failures) do
    ids =
      failures
      |> Enum.map(&related_id(&1.related, "article_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Article
    |> where([article], article.id in ^ids)
    |> select([article], {article.id, article.extraction_status})
    |> Repo.all()
    |> Map.new()
  end

  defp current_input_feeds(failures) do
    ids =
      failures
      |> Enum.map(&related_id(&1.related, "input_feed_id"))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    InputFeed
    |> where([feed], feed.id in ^ids)
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  defp actionable_failure?(failure, article_statuses, input_feeds) do
    article_id = related_id(failure.related, "article_id")
    input_feed_id = related_id(failure.related, "input_feed_id")

    cond do
      article_id -> Map.get(article_statuses, article_id) != "succeeded"
      input_feed_id -> not healthy_input_feed?(input_feeds[input_feed_id])
      true -> true
    end
  end

  defp healthy_input_feed?(%InputFeed{last_fetch_status: "ok"}), do: true
  defp healthy_input_feed?(_feed), do: false

  defp failure_group_key(failure, input_feeds) do
    input_feed_id = related_id(failure.related, "input_feed_id")
    input_feed = input_feeds[input_feed_id]
    url = failure.related["url"] || (failure.run && failure.run.related["url"])

    source =
      cond do
        input_feed -> input_feed.name
        url -> url_host(url)
        failure.related["generated_feed"] -> failure.related["generated_feed"]
        true -> "Application"
      end

    {failure.failure_type, source}
  end

  defp related_id(related, key) do
    case Map.get(related || %{}, key) do
      id when is_integer(id) -> id
      id when is_binary(id) -> parse_id(id)
      _ -> nil
    end
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp url_host(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
    |> to_string()
    |> String.downcase()
    |> String.trim_leading("www.")
  rescue
    _ -> "Unknown source"
  end
end
