defmodule Newspaper.Pipeline.Scheduler do
  use GenServer

  require Logger

  alias Newspaper.Operations
  alias Newspaper.Pipeline

  @default_interval_ms 5 * 60_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def fetch_now(server \\ __MODULE__), do: GenServer.cast(server, :fetch_now)

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(opts) do
    if Keyword.get(opts, :subscribe_to_events, true), do: Newspaper.Events.subscribe()

    state = %{
      fetcher: Keyword.get(opts, :fetcher, &Pipeline.fetch_all/1),
      interval_ms_provider: Keyword.get(opts, :interval_ms_provider, &configured_interval_ms/0),
      task_supervisor: Keyword.get(opts, :task_supervisor, Newspaper.Processing.TaskSupervisor),
      task: nil,
      timer: nil,
      next_fetch_at: nil
    }

    enabled =
      Keyword.get(
        opts,
        :enabled,
        Application.get_env(:newspaper, :pipeline_scheduler_enabled, true)
      )

    if enabled do
      delay = if Keyword.get(opts, :fetch_on_start, true), do: 0, else: interval_ms(state)
      {:ok, schedule_fetch(state, delay)}
    else
      {:ok, state}
    end
  end

  @impl true
  def handle_cast(:fetch_now, state) do
    {:noreply, state |> cancel_timer() |> start_fetch("manual")}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, %{running?: state.task != nil, next_fetch_at: state.next_fetch_at}, state}
  end

  @impl true
  def handle_info({:scheduled_fetch, token}, %{timer: {_timer, token}} = state) do
    {:noreply, state |> clear_timer() |> start_fetch("scheduled")}
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, _reason},
        %{task: %{ref: ref}} = state
      ) do
    {:noreply, state |> Map.put(:task, nil) |> schedule_next_fetch()}
  end

  def handle_info({:newspaper_data_changed, :settings_changed}, %{task: nil} = state) do
    {:noreply, state |> cancel_timer() |> schedule_next_fetch()}
  end

  def handle_info({:newspaper_data_changed, :settings_changed}, state), do: {:noreply, state}
  def handle_info({:newspaper_data_changed, _event}, state), do: {:noreply, state}
  def handle_info(_message, state), do: {:noreply, state}

  defp start_fetch(%{task: nil} = state, trigger) do
    case Task.Supervisor.start_child(state.task_supervisor, fn -> state.fetcher.(trigger) end) do
      {:ok, pid} ->
        %{state | task: %{pid: pid, ref: Process.monitor(pid)}}

      {:error, _reason} ->
        schedule_next_fetch(state)
    end
  end

  defp start_fetch(state, _trigger), do: state

  defp schedule_next_fetch(state), do: schedule_fetch(state, interval_ms(state))

  defp schedule_fetch(state, delay_ms) do
    token = make_ref()
    timer = Process.send_after(self(), {:scheduled_fetch, token}, delay_ms)

    %{
      state
      | timer: {timer, token},
        next_fetch_at: DateTime.add(DateTime.utc_now(), delay_ms, :millisecond)
    }
  end

  defp cancel_timer(%{timer: nil} = state), do: clear_timer(state)

  defp cancel_timer(%{timer: {timer, _token}} = state) do
    Process.cancel_timer(timer, async: false, info: false)
    clear_timer(state)
  end

  defp clear_timer(state), do: %{state | timer: nil, next_fetch_at: nil}

  defp interval_ms(state), do: max(state.interval_ms_provider.(), 1)

  defp configured_interval_ms do
    Operations.get_settings().fetch_interval_minutes * 60_000
  rescue
    error ->
      Logger.warning(
        "Could not load feed scheduler settings; using the default interval: " <>
          Exception.message(error)
      )

      @default_interval_ms
  end
end
