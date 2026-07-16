defmodule NewspaperWeb.AdminLive.Runs do
  use NewspaperWeb, :live_view

  alias Newspaper.Operations
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  @scopes ~w(overview all)
  @statuses ~w(all running succeeded failed)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, stream_configure(socket, :runs, dom_id: &"run-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    scope = allowed(params["scope"], @scopes, "overview")
    status = allowed(params["status"], @statuses, "all")

    {:noreply, assign_data(socket, scope, status)}
  end

  def handle_event("filter", %{"filters" => filters}, socket) do
    status = allowed(filters["status"], @statuses, "all")

    {:noreply,
     push_patch(socket,
       to: ~p"/runs?#{%{scope: socket.assigns.scope, status: status}}"
     )}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket, socket.assigns.scope, socket.assigns.status)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="runs" />

      <header class="mb-8">
        <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Operations
        </p>
        <h1 class="text-2xl font-semibold">Runs</h1>
        <p class="mt-1 text-sm text-base-content/65">
          High-level work by default, with low-level execution available for debugging.
        </p>
      </header>

      <div class="mb-6 flex flex-col gap-4 border-y border-base-300 py-4 sm:flex-row sm:items-center sm:justify-between">
        <div class="join" aria-label="Run detail level">
          <.link
            id="runs-scope-overview"
            patch={~p"/runs?#{%{scope: "overview", status: @status}}"}
            class={["join-item btn btn-sm", @scope == "overview" && "btn-active"]}
          >
            Operational
          </.link>
          <.link
            id="runs-scope-all"
            patch={~p"/runs?#{%{scope: "all", status: @status}}"}
            class={["join-item btn btn-sm", @scope == "all" && "btn-active"]}
          >
            All details
          </.link>
        </div>

        <.form for={@filter_form} id="runs-filter" phx-change="filter" class="w-full sm:w-48">
          <.input
            field={@filter_form[:status]}
            type="select"
            aria-label="Run status"
            options={[
              {"All statuses", "all"},
              {"Running", "running"},
              {"Succeeded", "succeeded"},
              {"Failed", "failed"}
            ]}
          />
        </.form>
      </div>

      <section
        id="runs-list"
        phx-update="stream"
        class="divide-y divide-base-300 border-y border-base-300"
      >
        <div id="runs-empty" class="hidden py-10 text-center only:block">
          <p class="font-medium">No runs match these filters.</p>
          <p class="mt-1 text-sm text-base-content/55">
            New activity will appear here automatically.
          </p>
        </div>

        <article
          :for={{dom_id, entry} <- @streams.runs}
          id={dom_id}
          class="grid gap-3 py-5 lg:grid-cols-[10rem_minmax(0,1fr)_8rem] lg:items-start"
        >
          <div>
            <p class="text-sm font-semibold">{Format.run_type_label(entry.run.run_type)}</p>
            <p class="mt-1 text-xs text-base-content/55">{Format.run_subject(entry)}</p>
          </div>

          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class={status_badge_class(entry.run.status)}>
                {Format.status_label(entry.run.status)}
              </span>
              <span class="text-xs text-base-content/50">{Format.duration(entry.run)}</span>
              <span class="text-xs text-base-content/45">
                {Format.run_type_label(entry.run.trigger)}
              </span>
            </div>
            <p class="mt-2 text-sm text-base-content/75">{Format.run_summary(entry)}</p>
            <p :if={entry.run.error_summary} class="mt-2 text-sm text-error">
              {entry.run.error_summary}
            </p>

            <details class="mt-3 text-xs text-base-content/60">
              <summary class="cursor-pointer font-medium hover:text-base-content">
                Debug details
              </summary>
              <pre class="mt-2 max-h-72 max-w-full overflow-auto whitespace-pre-wrap break-all bg-base-200 p-3 text-[0.7rem] leading-relaxed"><%= inspect(%{
                  related: entry.run.related,
                  summary: entry.run.summary_counts,
                  metadata: entry.run.debug_metadata
                }, pretty: true) %></pre>
            </details>
          </div>

          <div class="text-left text-xs text-base-content/55 lg:text-right">
            <.local_time id={"run-started-#{entry.id}"} value={entry.run.started_at} />
            <p :if={entry.run.finished_at} class="mt-1">Finished</p>
          </div>
        </article>
      </section>
    </Layouts.app>
    """
  end

  defp assign_data(socket, scope, status) do
    entries = Operations.list_run_entries(scope, status, 100)

    socket
    |> assign(:scope, scope)
    |> assign(:status, status)
    |> assign(:run_count, length(entries))
    |> assign(:filter_form, to_form(%{"status" => status}, as: :filters))
    |> stream(:runs, entries, reset: true)
  end

  defp allowed(value, allowed, fallback) do
    if value in allowed, do: value, else: fallback
  end

  defp status_badge_class("succeeded"), do: "badge badge-success badge-soft"
  defp status_badge_class("failed"), do: "badge badge-error badge-soft"
  defp status_badge_class("running"), do: "badge badge-info badge-soft"
  defp status_badge_class(_status), do: "badge badge-ghost"
end
