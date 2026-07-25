defmodule Newspaper.Operations.Recovery do
  use GenServer

  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    if Application.get_env(:newspaper, :operations_recovery_enabled, true) do
      {:ok, opts, {:continue, :recover}}
    else
      {:ok, opts}
    end
  end

  @impl true
  def handle_continue(:recover, state) do
    Newspaper.Operations.fail_interrupted_operation_runs()

    case Newspaper.Processing.materialize_missing_item_steps() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not reconcile pipeline item steps at startup: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
