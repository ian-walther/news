defmodule Newspaper.Processing.Dispatcher do
  use GenServer

  require Logger

  alias Newspaper.Content
  alias Newspaper.Extraction
  alias Newspaper.Processing
  alias Newspaper.Processing.PriorityQueue

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def enqueue(attempt_id, site_host, priority \\ :foreground)

  def enqueue(attempt_id, site_host, priority)
      when is_integer(attempt_id) and is_binary(site_host) do
    GenServer.cast(__MODULE__, {:enqueue, attempt_id, site_host, priority})
  end

  def enqueue(_attempt_id, _site_host, _priority), do: :ok

  def retry_now(site_host) when is_binary(site_host) do
    site_host =
      site_host
      |> String.trim()
      |> String.downcase()
      |> String.trim_leading("www.")

    GenServer.call(__MODULE__, {:retry_now, site_host})
  end

  def retry_now(_site_host), do: :empty

  @impl true
  def init(_state) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      send(self(), :recover)
    end

    {:ok, %{hosts: %{}}}
  end

  @impl true
  def handle_info(:recover, state) do
    Processing.requeue_interrupted_attempts("extraction")
    Processing.requeue_stranded_rate_limits("extraction")

    state =
      Processing.list_queued_attempts("extraction")
      |> Enum.reduce(state, fn attempt, state ->
        attempt = Processing.get_attempt!(attempt.id)
        url = attempt.article.resolved_url || attempt.article.canonical_url

        enqueue_attempt(
          state,
          attempt.id,
          Content.site_host(url),
          PriorityQueue.priority_for(attempt)
        )
      end)

    {:noreply, state}
  end

  def handle_info({:run_next, site_host, timer_token}, state) do
    case Map.get(state.hosts, site_host) do
      %{running?: false, timer_token: ^timer_token} = host_state ->
        state = put_host(state, site_host, clear_timer(host_state))
        {state, _result} = start_next(state, site_host)
        {:noreply, state}

      _host_state ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_call({:retry_now, site_host}, _from, state) do
    case Map.get(state.hosts, site_host) do
      nil ->
        {:reply, :empty, state}

      %{running?: true} ->
        {:reply, :already_running, state}

      host_state ->
        if PriorityQueue.empty?(host_state.queue) do
          {:reply, :empty, state}
        else
          state = put_host(state, site_host, cancel_timer(host_state))
          {state, result} = start_next(state, site_host)
          {:reply, result, state}
        end
    end
  end

  @impl true
  def handle_cast({:enqueue, attempt_id, site_host, priority}, state) do
    {:noreply, enqueue_attempt(state, attempt_id, site_host, priority)}
  end

  def handle_cast({:finished, site_host, result}, state) do
    schedule_automatic_retry(result)

    host_state = Map.fetch!(state.hosts, site_host)
    state = put_host(state, site_host, %{host_state | running?: false})
    {:noreply, schedule_host(state, site_host)}
  end

  defp enqueue_attempt(state, _attempt_id, nil, _priority), do: state

  defp enqueue_attempt(state, attempt_id, site_host, priority) do
    host_state = Map.get(state.hosts, site_host, new_host_state())
    host_state = %{host_state | queue: PriorityQueue.put(host_state.queue, attempt_id, priority)}

    state
    |> put_host(site_host, host_state)
    |> schedule_host(site_host)
  end

  defp schedule_host(state, site_host) do
    host_state = Map.fetch!(state.hosts, site_host)

    cond do
      host_state.running? or host_state.timer != nil or PriorityQueue.empty?(host_state.queue) ->
        state

      true ->
        delay =
          case Content.get_or_create_site_extraction_policy(site_host) do
            {:ok, policy} -> Content.extraction_wait_ms(policy)
            {:error, _reason} -> 0
          end

        timer_token = make_ref()
        timer = Process.send_after(self(), {:run_next, site_host, timer_token}, delay)
        put_host(state, site_host, %{host_state | timer: timer, timer_token: timer_token})
    end
  end

  defp new_host_state do
    %{queue: PriorityQueue.new(), running?: false, timer: nil, timer_token: nil}
  end

  defp start_next(state, site_host) do
    host_state = Map.fetch!(state.hosts, site_host)

    case PriorityQueue.pop(host_state.queue) do
      {{:value, attempt_id}, queue} ->
        host_state = %{clear_timer(host_state) | queue: queue, running?: true}
        state = put_host(state, site_host, host_state)

        result =
          Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
            result = Extraction.execute_attempt(attempt_id)
            GenServer.cast(__MODULE__, {:finished, site_host, result})
          end)

        case result do
          {:ok, pid} ->
            {state, {:started, pid}}

          {:error, reason} ->
            GenServer.cast(__MODULE__, {:finished, site_host, {:error, reason}})
            {state, {:error, reason}}
        end

      {:empty, _queue} ->
        {put_host(state, site_host, clear_timer(host_state)), :empty}
    end
  end

  defp cancel_timer(%{timer: nil} = host_state), do: clear_timer(host_state)

  defp cancel_timer(host_state) do
    Process.cancel_timer(host_state.timer, async: false, info: false)
    clear_timer(host_state)
  end

  defp clear_timer(host_state), do: %{host_state | timer: nil, timer_token: nil}

  defp put_host(state, site_host, host_state) do
    put_in(state, [:hosts, site_host], host_state)
  end

  defp schedule_automatic_retry({:ok, attempt}) do
    case Processing.schedule_automatic_retry(attempt) do
      {:ok, _retry_attempt} ->
        :ok

      {:error, reason} ->
        Logger.warning("Could not schedule automatic extraction retry: #{inspect(reason)}")
    end
  end

  defp schedule_automatic_retry(_result), do: :ok
end
