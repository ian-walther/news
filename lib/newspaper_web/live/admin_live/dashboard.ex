defmodule NewspaperWeb.AdminLive.Dashboard do
  use NewspaperWeb, :live_view

  alias Newspaper.{Operations, Pipeline}
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, assign_data(socket)}
  end

  def handle_event("fetch_all", _params, socket) do
    Pipeline.Scheduler.fetch_now()
    {:noreply, put_flash(assign_data(socket), :info, "Fetch started")}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <div class="mb-6 flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold">Failures / Recent Activity</h1>
          <p class="text-sm text-base-content/70">Operational landing page for the V1 pipeline.</p>
        </div>
        <button class="btn btn-primary" phx-click="fetch_all">Fetch all now</button>
      </div>

      <section class="mb-8">
        <h2 class="mb-3 text-lg font-semibold">Recent Failures</h2>
        <.table id="failures" rows={@failures}>
          <:col :let={failure} label="Type">{failure.failure_type}</:col>
          <:col :let={failure} label="Message">{failure.message}</:col>
          <:col :let={failure} label="Retryable">{if failure.retryable, do: "yes", else: "no"}</:col>
          <:col :let={failure} label="At">{failure.inserted_at}</:col>
        </.table>
      </section>

      <section>
        <h2 class="mb-3 text-lg font-semibold">Recent Runs</h2>
        <.table id="runs" rows={@runs}>
          <:col :let={run} label="Type">{run.run_type}</:col>
          <:col :let={run} label="Trigger">{run.trigger}</:col>
          <:col :let={run} label="Status">{run.status}</:col>
          <:col :let={run} label="Started">{run.started_at}</:col>
          <:col :let={run} label="Summary">{inspect(run.summary_counts)}</:col>
        </.table>
      </section>
    </main>
    """
  end

  defp assign_data(socket) do
    socket
    |> assign(:failures, Operations.list_failures())
    |> assign(:runs, Operations.list_runs())
  end
end
