defmodule Newspaper.Processing.Dispatcher do
  use GenServer

  alias Newspaper.Content
  alias Newspaper.Extraction
  alias Newspaper.Processing

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def enqueue(attempt_id, site_host) when is_integer(attempt_id) and is_binary(site_host) do
    GenServer.cast(__MODULE__, {:enqueue, attempt_id, site_host})
  end

  def enqueue(_attempt_id, _site_host), do: :ok

  @impl true
  def init(_state) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      send(self(), :recover)
    end

    {:ok, %{hosts: %{}}}
  end

  @impl true
  def handle_info(:recover, state) do
    Processing.requeue_interrupted_attempts()

    state =
      Processing.list_queued_attempts()
      |> Enum.reduce(state, fn attempt, state ->
        attempt = Processing.get_attempt!(attempt.id)
        url = attempt.article.resolved_url || attempt.article.canonical_url
        enqueue_attempt(state, attempt.id, Content.site_host(url))
      end)

    {:noreply, state}
  end

  def handle_info({:run_next, site_host}, state) do
    host_state = Map.fetch!(state.hosts, site_host)

    case :queue.out(host_state.queue) do
      {{:value, attempt_id}, queue} ->
        host_state = %{host_state | queue: queue, running?: true, timer: nil}
        state = put_host(state, site_host, host_state)

        case Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
               result = Extraction.execute_attempt(attempt_id)
               GenServer.cast(__MODULE__, {:finished, site_host, result})
             end) do
          {:ok, _pid} ->
            {:noreply, state}

          {:error, reason} ->
            GenServer.cast(__MODULE__, {:finished, site_host, {:error, reason}})
            {:noreply, state}
        end

      {:empty, _queue} ->
        {:noreply, put_host(state, site_host, %{host_state | timer: nil})}
    end
  end

  @impl true
  def handle_cast({:enqueue, attempt_id, site_host}, state) do
    {:noreply, enqueue_attempt(state, attempt_id, site_host)}
  end

  def handle_cast({:finished, site_host, _result}, state) do
    host_state = Map.fetch!(state.hosts, site_host)
    state = put_host(state, site_host, %{host_state | running?: false})
    {:noreply, schedule_host(state, site_host)}
  end

  defp enqueue_attempt(state, _attempt_id, nil), do: state

  defp enqueue_attempt(state, attempt_id, site_host) do
    host_state = Map.get(state.hosts, site_host, new_host_state())

    host_state =
      if attempt_id in :queue.to_list(host_state.queue) do
        host_state
      else
        %{host_state | queue: :queue.in(attempt_id, host_state.queue)}
      end

    state
    |> put_host(site_host, host_state)
    |> schedule_host(site_host)
  end

  defp schedule_host(state, site_host) do
    host_state = Map.fetch!(state.hosts, site_host)

    cond do
      host_state.running? or host_state.timer != nil or :queue.is_empty(host_state.queue) ->
        state

      true ->
        delay =
          case Content.get_or_create_site_extraction_policy(site_host) do
            {:ok, policy} -> Content.extraction_wait_ms(policy)
            {:error, _reason} -> 0
          end

        timer = Process.send_after(self(), {:run_next, site_host}, delay)
        put_host(state, site_host, %{host_state | timer: timer})
    end
  end

  defp new_host_state do
    %{queue: :queue.new(), running?: false, timer: nil}
  end

  defp put_host(state, site_host, host_state) do
    put_in(state, [:hosts, site_host], host_state)
  end
end
