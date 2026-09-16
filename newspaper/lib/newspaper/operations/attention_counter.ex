defmodule Newspaper.Operations.AttentionCounter do
  @moduledoc """
  One shared, coalesced attention count for every viewer. Recomputes (from
  aggregate queries only) after a burst of data events and on a bounded
  clock, and broadcasts only when the number changes (audit IMP-13/18).
  """

  use GenServer
  require Logger

  @topic "newspaper:attention"
  @debounce_ms 300
  @tick_ms 30_000
  @events [
    :processing_changed,
    :operations_changed,
    :intake_changed,
    :publishing_changed,
    :site_extraction_policies_changed
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Newspaper.PubSub, @topic)

  @doc "The current cached count; computed on first use."
  def current do
    GenServer.call(__MODULE__, :current)
  catch
    :exit, _reason -> 0
  end

  @doc "Forces a synchronous recompute (tests)."
  def refresh, do: GenServer.call(__MODULE__, :refresh)

  @impl true
  # Event and clock-driven recomputes can be switched off (tests); reads
  # then compute on demand only.
  def init(_opts) do
    if Application.get_env(:newspaper, :attention_counter_background, true) do
      Newspaper.Events.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    {:ok, %{count: nil, pending: false}}
  end

  @impl true
  # A first read, or a read while a recompute is pending, computes now so a
  # page that mounts right after a change never shows a stale number.
  def handle_call(:current, _from, %{count: nil} = state) do
    state = recompute(state)
    {:reply, state.count || 0, state}
  end

  def handle_call(:current, _from, %{pending: true} = state) do
    state = recompute(state)
    {:reply, state.count || 0, state}
  end

  def handle_call(:current, _from, state) do
    if Application.get_env(:newspaper, :attention_counter_background, true) do
      {:reply, state.count, state}
    else
      state = recompute(state)
      {:reply, state.count || 0, state}
    end
  end

  def handle_call(:refresh, _from, state) do
    state = recompute(state)
    {:reply, state.count || 0, state}
  end

  @impl true
  def handle_info({:newspaper_data_changed, event}, %{pending: false} = state)
      when event in @events do
    Process.send_after(self(), :recompute, @debounce_ms)
    {:noreply, %{state | pending: true}}
  end

  def handle_info({:newspaper_data_changed, _event}, state), do: {:noreply, state}

  def handle_info(:recompute, state), do: {:noreply, recompute(%{state | pending: false})}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, recompute(state)}
  end

  defp recompute(state) do
    count = Newspaper.Operations.Attention.count()

    if count != state.count do
      Phoenix.PubSub.broadcast(Newspaper.PubSub, @topic, {:attention_count, count})
    end

    %{state | count: count}
  rescue
    error ->
      Logger.debug("attention count skipped: #{Exception.message(error)}")
      state
  end
end
