defmodule NewspaperWeb.AdminLive.Runs do
  use NewspaperWeb, :live_view

  alias Newspaper.Operations
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Runs</h1>
      <.table id="runs-list" rows={@runs}>
        <:col :let={run} label="Type">{run.run_type}</:col>
        <:col :let={run} label="Trigger">{run.trigger}</:col>
        <:col :let={run} label="Status">{run.status}</:col>
        <:col :let={run} label="Started">{run.started_at}</:col>
        <:col :let={run} label="Finished">{run.finished_at}</:col>
        <:col :let={run} label="Summary">{inspect(run.summary_counts)}</:col>
      </.table>
    </main>
    """
  end

  defp assign_data(socket) do
    assign(socket, :runs, Operations.list_runs(100))
  end
end
