defmodule Newspaper.PipelineSchedulerTest do
  use ExUnit.Case

  alias Newspaper.Pipeline.Scheduler

  setup do
    task_supervisor =
      start_supervised!({Task.Supervisor, name: unique_name("pipeline-scheduler-tasks")})

    %{task_supervisor: task_supervisor}
  end

  test "fetches immediately on startup and does not overlap fetches", %{
    task_supervisor: task_supervisor
  } do
    parent = self()

    fetcher = fn trigger ->
      send(parent, {:fetch_started, trigger, self()})

      receive do
        :finish -> :ok
      end
    end

    start_supervised!(
      {Scheduler,
       name: unique_name("pipeline-scheduler"),
       task_supervisor: task_supervisor,
       fetcher: fetcher,
       interval_ms_provider: fn -> 10 end,
       enabled: true,
       subscribe_to_events: false}
    )

    assert_receive {:fetch_started, "scheduled", first_fetch}
    refute_receive {:fetch_started, "scheduled", _pid}, 50

    send(first_fetch, :finish)
    assert_receive {:fetch_started, "scheduled", second_fetch}, 200
    send(second_fetch, :finish)
  end

  test "rearms the current timer when fetch settings change", %{
    task_supervisor: task_supervisor
  } do
    parent = self()
    interval = start_supervised!({Agent, fn -> 60_000 end})

    scheduler =
      start_supervised!(
        {Scheduler,
         name: unique_name("pipeline-scheduler"),
         task_supervisor: task_supervisor,
         fetcher: fn trigger -> send(parent, {:fetch_started, trigger}) end,
         interval_ms_provider: fn -> Agent.get(interval, & &1) end,
         enabled: true,
         fetch_on_start: false,
         subscribe_to_events: false}
      )

    Agent.update(interval, fn _interval -> 10 end)
    send(scheduler, {:newspaper_data_changed, :settings_changed})

    assert_receive {:fetch_started, "scheduled"}, 200
  end

  defp unique_name(prefix) do
    String.to_atom("#{prefix}-#{System.unique_integer([:positive])}")
  end
end
