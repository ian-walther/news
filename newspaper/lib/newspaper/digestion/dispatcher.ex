defmodule Newspaper.Digestion.Dispatcher do
  use GenServer

  alias Newspaper.Digestion
  alias Newspaper.Processing
  alias Newspaper.Processing.PriorityQueue

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def enqueue(attempt_id, priority \\ :foreground) when is_integer(attempt_id) do
    GenServer.cast(__MODULE__, {:enqueue, attempt_id, priority})
  end

  @impl true
  def init(_state) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      send(self(), :recover)
    end

    {:ok, %{queue: PriorityQueue.new(), running?: false}}
  end

  @impl true
  def handle_info(:recover, state) do
    Processing.requeue_interrupted_attempts("digestion")

    state =
      Processing.list_queued_attempts("digestion")
      |> Enum.reduce(state, fn attempt, state ->
        enqueue_attempt(state, attempt.id, PriorityQueue.priority_for(attempt))
      end)

    {:noreply, start_next(state)}
  end

  @impl true
  def handle_cast({:enqueue, attempt_id, priority}, state) do
    state = state |> enqueue_attempt(attempt_id, priority) |> start_next()
    {:noreply, state}
  end

  def handle_cast({:finished, _result}, state) do
    {:noreply, state |> Map.put(:running?, false) |> start_next()}
  end

  defp enqueue_attempt(state, attempt_id, priority) do
    %{state | queue: PriorityQueue.put(state.queue, attempt_id, priority)}
  end

  defp start_next(%{running?: true} = state), do: state

  defp start_next(state) do
    case PriorityQueue.pop(state.queue) do
      {{:value, attempt_id}, queue} ->
        state = %{state | queue: queue, running?: true}

        case Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
               result = Digestion.execute_attempt(attempt_id)
               GenServer.cast(__MODULE__, {:finished, result})
             end) do
          {:ok, _pid} ->
            state

          {:error, reason} ->
            GenServer.cast(__MODULE__, {:finished, {:error, reason}})
            state
        end

      {:empty, _queue} ->
        state
    end
  end
end
