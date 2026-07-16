defmodule Newspaper.Operations do
  import Ecto.Query

  alias Newspaper.Operations.{AppSettings, Failure, Run}
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
end
