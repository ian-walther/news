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

    {:ok,
     %{
       queue: PriorityQueue.new(),
       running?: false,
       task_pid: nil,
       task_ref: nil,
       attempt_id: nil
     }}
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

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task_ref: ref} = state) do
    Processing.fail_dispatched_attempt(
      state.attempt_id,
      "dispatcher_task_exit",
      "Digestion dispatcher task exited: #{inspect(reason)}"
    )

    {:noreply, state |> clear_running() |> start_next()}
  end

  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def handle_cast({:enqueue, attempt_id, priority}, state) do
    state = state |> enqueue_attempt(attempt_id, priority) |> start_next()
    {:noreply, state}
  end

  def handle_cast({:finished, task_pid, _result}, %{task_pid: task_pid} = state) do
    Process.demonitor(state.task_ref, [:flush])
    {:noreply, state |> clear_running() |> start_next()}
  end

  def handle_cast({:finished, _task_pid, _result}, state), do: {:noreply, state}

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
               GenServer.cast(__MODULE__, {:finished, self(), result})
             end) do
          {:ok, pid} ->
            %{
              state
              | task_pid: pid,
                task_ref: Process.monitor(pid),
                attempt_id: attempt_id
            }

          {:error, reason} ->
            Processing.fail_dispatched_attempt(
              attempt_id,
              "dispatcher_start_failed",
              "Could not start digestion task: #{inspect(reason)}"
            )

            state |> clear_running() |> start_next()
        end

      {:empty, _queue} ->
        state
    end
  end

  defp clear_running(state) do
    %{state | running?: false, task_pid: nil, task_ref: nil, attempt_id: nil}
  end
end
