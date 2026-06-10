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
    <main class="mx-auto max-w-3xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Settings</h1>
      <.form for={@form} phx-submit="save" class="space-y-4">
        <.input
          field={@form[:fetch_interval_minutes]}
          label="Global fetch interval minutes"
          type="number"
        />
        <.input field={@form[:run_history_enabled]} label="Run history/debug logging" type="checkbox" />
        <.button>Save settings</.button>
      </.form>
    </main>
    """
  end

  defp assign_data(socket) do
    settings = Operations.get_settings()
    assign(socket, settings: settings, form: to_form(Operations.change_settings(settings)))
  end
end
