defmodule NewspaperWeb.AdminLive.Settings do
  use NewspaperWeb, :live_view

  alias Newspaper.Operations
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, assign_data(socket)}
  end

  def handle_event("save", %{"app_settings" => params}, socket) do
    case Operations.update_settings(socket.assigns.settings, params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings saved")
         |> assign(settings: settings, form: to_form(Operations.change_settings(settings)))}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_info({:newspaper_data_changed, :settings_changed}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, socket}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="settings" />
      <div class="max-w-3xl">
        <header class="mb-8">
          <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Application
          </p>
          <h1 class="text-2xl font-semibold">Settings</h1>
          <p class="mt-1 text-sm text-base-content/65">Global scheduling and diagnostics.</p>
        </header>
        <.form
          for={@form}
          id="settings-form"
          phx-submit="save"
          class="space-y-5 border-y border-base-300 py-6"
        >
          <.input
            field={@form[:fetch_interval_minutes]}
            label="Global fetch interval minutes"
            type="number"
          />
          <.input
            field={@form[:run_history_enabled]}
            label="Run history/debug logging"
            type="checkbox"
          />
          <.button><.icon name="hero-check" class="size-4" /> Save settings</.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  defp assign_data(socket) do
    settings = Operations.get_settings()
    assign(socket, settings: settings, form: to_form(Operations.change_settings(settings)))
  end
end
