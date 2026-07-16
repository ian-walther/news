defmodule Newspaper.Pipeline.Scheduler do
  use GenServer

  alias Newspaper.Operations
  alias Newspaper.Pipeline

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def fetch_now, do: GenServer.cast(__MODULE__, :fetch_now)

  @impl true
  def init(state) do
    schedule_next_fetch()
    {:ok, state}
  end

  @impl true
  def handle_cast(:fetch_now, state) do
    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Pipeline.fetch_all("manual")
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_fetch, state) do
    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Pipeline.fetch_all("scheduled")
    end)

    schedule_next_fetch()
    {:noreply, state}
  end

  defp schedule_next_fetch do
    interval_ms =
      try do
        Operations.get_settings().fetch_interval_minutes * 60_000
      rescue
        _ -> 60 * 60_000
      end

    Process.send_after(self(), :scheduled_fetch, interval_ms)
  end
end
