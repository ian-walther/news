defmodule Newspaper.Processing.BatchDispatcher do
  use GenServer

  alias Newspaper.Processing

  def start_link(_opts), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  def enqueue(batch_id) when is_integer(batch_id) do
    GenServer.call(__MODULE__, {:enqueue, batch_id})
  end

  def recover do
    GenServer.call(__MODULE__, :recover)
  end

  def await(batch_id, timeout \\ 5_000) when is_integer(batch_id) do
    case GenServer.call(__MODULE__, {:task_pid, batch_id}) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc] -> :ok
          {:DOWN, ^ref, :process, ^pid, reason} -> {:error, reason}
        after
          timeout -> {:error, :timeout}
        end
    end
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :recover}}

  @impl true
  def handle_continue(:recover, state) do
    {_count, state} = recover_batches(state)
    {:noreply, state}
  end

  @impl true
  def handle_call({:enqueue, batch_id}, _from, state) do
    case start_batch(state, batch_id) do
      {:ok, state} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:recover, _from, state) do
    {count, state} = recover_batches(state)
    {:reply, {:ok, count}, state}
  end

  def handle_call({:task_pid, batch_id}, _from, state) do
    {:reply, get_in(state, [batch_id, :pid]), state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state, fn {_batch_id, task} -> task.ref == ref end) do
      {batch_id, _task} ->
        if reason != :normal, do: Processing.fail_feed_batch(batch_id, reason)
        {:noreply, Map.delete(state, batch_id)}

      nil ->
        {:noreply, state}
    end
  end

  defp recover_batches(state) do
    Processing.list_running_feed_batches()
    |> Enum.reduce({0, state}, fn batch, {count, state} ->
      case start_batch(state, batch.id) do
        {:ok, state} -> {count + 1, state}
        {:error, _reason, state} -> {count, state}
      end
    end)
  end

  defp start_batch(state, batch_id) do
    if Map.has_key?(state, batch_id) do
      {:ok, state}
    else
      case Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
             Processing.resume_feed_batch(batch_id)
           end) do
        {:ok, pid} ->
          ref = Process.monitor(pid)
          {:ok, Map.put(state, batch_id, %{pid: pid, ref: ref})}

        {:error, reason} ->
          _ = Processing.fail_feed_batch(batch_id, reason)
          {:error, reason, state}
      end
    end
  end
end
