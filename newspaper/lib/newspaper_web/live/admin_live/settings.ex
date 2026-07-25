defmodule NewspaperWeb.AdminLive.Settings do
  use NewspaperWeb, :live_view

  alias Newspaper.Operations
  alias Newspaper.Digestion
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Newspaper.Events.subscribe()
      send(self(), :discover_ollama_models)
    end

    {:ok,
     socket
     |> assign(:ollama_models, [])
     |> assign(:ollama_status, :unchecked)
     |> assign_data()}
  end

  def handle_event("save", %{"app_settings" => params}, socket) do
    case Operations.update_settings(socket.assigns.settings, params) do
      {:ok, settings} ->
        {:noreply,
         socket
         |> put_flash(:info, "Settings saved")
         |> assign(settings: settings, form: to_form(Operations.change_settings(settings)))
         |> start_model_discovery()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("refresh_ollama_models", _params, socket) do
    {:noreply, start_model_discovery(socket)}
  end

  def handle_info(:discover_ollama_models, socket) do
    {:noreply, start_model_discovery(socket)}
  end

  def handle_info({:newspaper_data_changed, :settings_changed}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, socket}
  end

  def handle_async(:discover_ollama_models, {:ok, {:ok, models}}, socket) do
    {:noreply,
     socket
     |> assign(:ollama_models, models)
     |> assign(:ollama_status, {:connected, length(models)})}
  end

  def handle_async(:discover_ollama_models, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, :ollama_status, {:error, reason})}
  end

  def handle_async(:discover_ollama_models, {:exit, reason}, socket) do
    {:noreply, assign(socket, :ollama_status, {:error, inspect(reason)})}
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
          <p class="mt-1 text-sm text-base-content/65">
            Global scheduling, diagnostics, and local model runtime.
          </p>
        </header>
        <.form
          for={@form}
          id="settings-form"
          phx-submit="save"
          class="space-y-8 border-y border-base-300 py-6"
        >
          <section class="space-y-4">
            <div>
              <h2 class="text-base font-semibold">Collection</h2>
              <p class="mt-1 text-sm text-base-content/55">Feed scheduling.</p>
            </div>
            <.input
              field={@form[:fetch_interval_minutes]}
              label="Global fetch interval minutes"
              type="number"
            />
          </section>

          <section class="space-y-4 border-t border-base-300 pt-6">
            <div class="flex flex-wrap items-start justify-between gap-3">
              <div>
                <h2 class="text-base font-semibold">Ollama</h2>
                <p class="mt-1 text-sm text-base-content/55">
                  Connection and model used for article digestion.
                </p>
              </div>
              <button
                id="refresh-ollama-models"
                type="button"
                class="btn btn-sm"
                phx-click="refresh_ollama_models"
                disabled={@ollama_status == :loading}
              >
                <.icon name="hero-arrow-path" class="size-4" />
                {if @ollama_status == :loading, do: "Checking...", else: "Refresh models"}
              </button>
            </div>
            <.input
              field={@form[:ollama_base_url]}
              label="Ollama URL"
              placeholder="http://desktop.home:11434"
            />
            <.input
              field={@form[:ollama_model]}
              label="Article digestion model"
              type="select"
              prompt="Select a discovered model"
              options={model_options(assigns)}
            />
            <p id="ollama-connection-status" class={ollama_status_class(@ollama_status)}>
              {ollama_status_text(@ollama_status)}
            </p>
          </section>
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

  defp start_model_discovery(socket) do
    base_url = socket.assigns.settings.ollama_base_url

    socket
    |> assign(:ollama_status, :loading)
    |> start_async(:discover_ollama_models, fn -> Digestion.list_models(base_url) end)
  end

  defp model_options(assigns) do
    models =
      case assigns.settings.ollama_model do
        model when is_binary(model) and model != "" -> [model | assigns.ollama_models]
        _model -> assigns.ollama_models
      end

    models
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&{&1, &1})
  end

  defp ollama_status_text(:unchecked), do: "Connection not checked"
  defp ollama_status_text(:loading), do: "Checking Ollama..."
  defp ollama_status_text({:connected, 1}), do: "Connected · 1 model available"
  defp ollama_status_text({:connected, count}), do: "Connected · #{count} models available"
  defp ollama_status_text({:error, reason}), do: "Unavailable · #{reason}"

  defp ollama_status_class({:connected, _count}), do: "text-sm text-success"
  defp ollama_status_class({:error, _reason}), do: "text-sm text-error"
  defp ollama_status_class(_status), do: "text-sm text-base-content/55"
end
