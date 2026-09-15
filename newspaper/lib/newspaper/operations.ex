defmodule Newspaper.Operations do
  import Ecto.Query

  alias Newspaper.Intake.InputFeed
  alias Newspaper.Operations.{AppSettings, Failure, Run}
  alias Newspaper.Publishing.GeneratedFeed
  alias Newspaper.Repo

  def get_settings do
    Repo.one(from s in AppSettings, order_by: [asc: s.id], limit: 1) ||
      create_default_settings()
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

  def digestion_paused?, do: get_settings().digestion_paused

  def get_run!(id), do: Repo.get!(Run, id)

  def latest_run(run_type) do
    Run
    |> where([run], run.run_type == ^run_type)
    |> order_by([run], desc: run.started_at, desc: run.id)
    |> limit(1)
    |> Repo.one()
  end

  def list_processing_run_entries(opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    Run
    |> where([run], run.run_type != "pipeline_step")
    |> filter_processing_run_stage(Keyword.get(opts, :stage))
    |> filter_processing_run_feed(Keyword.get(opts, :generated_feed_id))
    |> filter_processing_run_article(Keyword.get(opts, :article_id))
    |> filter_processing_run_batch(Keyword.get(opts, :batch_run_id))
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
      debug_metadata: Map.put(debug_metadata, "owner", inspect(self())),
      pipeline_step_attempt_id: related_id(related, "pipeline_step_attempt_id")
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

  def fail_running_pipeline_step_runs(attempt_id, message) when is_integer(attempt_id) do
    {count, _rows} =
      Run
      |> where(
        [run],
        run.run_type == "pipeline_step" and run.status == "running" and
          run.pipeline_step_attempt_id == ^attempt_id
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          finished_at: DateTime.utc_now(:second),
          error_summary: message
        ]
      )

    if count > 0, do: Newspaper.Events.broadcast_data_changed(:operations_changed)
    :ok
  end

  def fail_interrupted_operation_runs do
    {count, _rows} =
      Run
      |> where(
        [run],
        run.status == "running" and run.run_type not in ["pipeline_step", "pipeline_batch"]
      )
      |> Repo.update_all(
        set: [
          status: "failed",
          finished_at: DateTime.utc_now(:second),
          error_summary: "Application restarted while run was in progress"
        ]
      )

    if count > 0, do: Newspaper.Events.broadcast_data_changed(:operations_changed)
    count
  end

  @doc """
  Whether the process that started `run` is still alive on this node. A run
  started before a restart parses to a pid from another node incarnation and
  is reported dead, which is the correct answer.
  """
  def run_owner_alive?(%Run{debug_metadata: metadata}) do
    case metadata["owner"] do
      "#PID" <> rest ->
        try do
          rest |> String.to_charlist() |> :erlang.list_to_pid() |> Process.alive?()
        rescue
          ArgumentError -> false
        end

      _owner ->
        false
    end
  end

  @doc "Closes a run the operator has judged abandoned; refuses if it already finished."
  def close_run_as_failed(run_id) when is_integer(run_id) do
    now = DateTime.utc_now(:second)

    {count, _rows} =
      Run
      |> where([run], run.id == ^run_id and run.status == "running")
      |> Repo.update_all(
        set: [
          status: "failed",
          finished_at: now,
          error_summary: "Closed by operator: the run had no live owner",
          updated_at: now
        ]
      )

    case count do
      1 ->
        Newspaper.Events.broadcast_data_changed(:operations_changed)
        {:ok, get_run!(run_id)}

      0 ->
        {:error, :not_running}
    end
  end

  @doc """
  Marks unresolved failure records resolved when the thing they were about has
  since been processed successfully. `criteria` is a list of `{related_key,
  value}` pairs; a failure matches when every pair matches its `related` map.
  """
  def resolve_failures(failure_types, criteria)
      when is_list(failure_types) and is_list(criteria) do
    query =
      Enum.reduce(
        criteria,
        from(f in Failure, where: f.failure_type in ^failure_types and is_nil(f.resolved_at)),
        fn
          {"id", value}, query when is_integer(value) ->
            where(query, [f], f.id == ^value)

          {key, value}, query when is_integer(value) ->
            where(query, [f], fragment("(?->>?)::bigint = ?", f.related, ^key, ^value))

          {key, value}, query when is_binary(value) ->
            where(query, [f], fragment("?->>? = ?", f.related, ^key, ^value))
        end
      )

    {count, _rows} = Repo.update_all(query, set: [resolved_at: DateTime.utc_now(:second)])
    if count > 0, do: Newspaper.Events.broadcast_data_changed(:operations_changed)
    count
  end

  def unresolved_failures?(failure_types) when is_list(failure_types) do
    Failure
    |> where([f], f.failure_type in ^failure_types and is_nil(f.resolved_at))
    |> Repo.exists?()
  end

  def list_unresolved_failures(failure_types) when is_list(failure_types) do
    Failure
    |> where([f], f.failure_type in ^failure_types and is_nil(f.resolved_at))
    |> order_by([f], desc: f.inserted_at, desc: f.id)
    |> Repo.all()
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

  defp create_default_settings do
    %AppSettings{}
    |> AppSettings.changeset(%{})
    |> Repo.insert(on_conflict: :nothing)

    Repo.one!(from settings in AppSettings, order_by: [asc: settings.id], limit: 1)
  end

  defp broadcast_on_ok({:ok, value}, event) do
    Newspaper.Events.broadcast_data_changed(event)
    {:ok, value}
  end

  defp broadcast_on_ok(result, _event), do: result

  defp filter_processing_run_stage(query, stage)
       when stage in ["extraction", "digestion"] do
    where(
      query,
      [run],
      run.run_type == "pipeline_batch" and
        fragment("jsonb_extract_path_text(?, 'step_type') = ?", run.related, ^stage)
    )
  end

  defp filter_processing_run_stage(query, "operations") do
    where(query, [run], run.run_type != "pipeline_batch")
  end

  defp filter_processing_run_stage(query, _stage), do: query

  defp filter_processing_run_feed(query, generated_feed_id)
       when is_integer(generated_feed_id) do
    generated_feed_id = Integer.to_string(generated_feed_id)

    where(
      query,
      [run],
      fragment(
        "jsonb_extract_path_text(?, 'generated_feed_id') = ?",
        run.related,
        ^generated_feed_id
      )
    )
  end

  defp filter_processing_run_feed(query, _generated_feed_id), do: query

  defp filter_processing_run_article(query, article_id) when is_integer(article_id) do
    article_id = Integer.to_string(article_id)

    where(
      query,
      [run],
      fragment("jsonb_extract_path_text(?, 'article_id') = ?", run.related, ^article_id)
    )
  end

  defp filter_processing_run_article(query, _article_id), do: query

  defp filter_processing_run_batch(query, batch_run_id) when is_integer(batch_run_id) do
    where(query, [run], run.id == ^batch_run_id)
  end

  defp filter_processing_run_batch(query, _batch_run_id), do: query

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
end
