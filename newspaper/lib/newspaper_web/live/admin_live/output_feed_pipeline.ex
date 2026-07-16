defmodule NewspaperWeb.AdminLive.OutputFeedPipeline do
  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav

  alias Newspaper.Processing
  alias Newspaper.Processing.Registry
  alias Newspaper.Publishing

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    feed = Publishing.get_generated_feed!(String.to_integer(id))

    {:ok,
     socket
     |> assign(:feed, feed)
     |> assign(:editing_step_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:implementations, Registry.all())
     |> assign_new_form()
     |> assign_steps()}
  end

  def handle_event("create_step", %{"pipeline_step" => params}, socket) do
    case Processing.create_step(socket.assigns.feed, params) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pipeline step created")
         |> assign_new_form()
         |> assign_steps()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:form, to_form(params, as: :pipeline_step))}
    end
  end

  def handle_event("edit_step", %{"id" => id}, socket) do
    step = Processing.get_step!(String.to_integer(id))

    params = %{
      "enabled" => step.enabled,
      "timeout_ms" => step.config["timeout_ms"],
      "minimum_text_length" => step.config["minimum_text_length"]
    }

    {:noreply,
     socket
     |> assign(:editing_step_id, step.id)
     |> assign(:edit_form, to_form(params, as: :pipeline_step))
     |> assign_steps()}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket |> assign(:editing_step_id, nil) |> assign(:edit_form, nil) |> assign_steps()}
  end

  def handle_event("update_step", %{"pipeline_step" => params}, socket) do
    step = Processing.get_step!(socket.assigns.editing_step_id)

    case Processing.update_step(step, params) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pipeline step updated")
         |> assign(:editing_step_id, nil)
         |> assign(:edit_form, nil)
         |> assign_steps()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))
         |> assign(:edit_form, to_form(params, as: :pipeline_step))}
    end
  end

  def handle_event("toggle_step", %{"id" => id}, socket) do
    step = Processing.get_step!(String.to_integer(id))
    {:ok, _step} = Processing.update_step(step, %{enabled: !step.enabled})
    {:noreply, assign_steps(socket)}
  end

  def handle_event("delete_step", %{"id" => id}, socket) do
    step = Processing.get_step!(String.to_integer(id))
    {:ok, _step} = Processing.delete_step(step)
    {:noreply, socket |> put_flash(:info, "Pipeline step deleted") |> assign_steps()}
  end

  def handle_event("move_step", %{"id" => id, "direction" => direction}, socket) do
    step = Processing.get_step!(String.to_integer(id))
    direction = if direction == "up", do: :up, else: :down
    {:ok, _step} = Processing.move_step(step, direction)
    {:noreply, assign_steps(socket)}
  end

  def handle_event("process_existing", _params, socket) do
    case Processing.enqueue_feed(socket.assigns.feed.id, force: true) do
      {:ok, 0} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "No articles were queued. Enable processing and add an extraction step first."
         )}

      {:ok, count} ->
        {:noreply, put_flash(socket, :info, "Queued #{count} extraction attempts")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_steps(socket)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav />

      <div class="mb-6 flex flex-wrap items-center justify-between gap-3">
        <div>
          <p class="text-sm text-base-content/60">Output feed pipeline</p>
          <h1 class="text-2xl font-semibold">{@feed.title}</h1>
        </div>
        <button
          id="process-existing-items"
          type="button"
          phx-click="process_existing"
          class="btn btn-primary"
        >
          <.icon name="hero-play" class="size-4" /> Process existing items
        </button>
      </div>

      <section class="mb-8 border-y border-base-300 py-6">
        <h2 class="mb-4 text-lg font-semibold">Add Step</h2>
        <.form
          for={@form}
          id="new-pipeline-step-form"
          phx-submit="create_step"
          class="grid gap-4 md:grid-cols-3"
        >
          <.input
            field={@form[:implementation_key]}
            type="select"
            label="Implementation"
            options={Enum.map(@implementations, &{&1.label, &1.key})}
          />
          <.input field={@form[:timeout_ms]} type="number" label="Timeout (ms)" />
          <.input
            field={@form[:minimum_text_length]}
            type="number"
            label="Minimum text length"
          />
          <div class="md:col-span-3">
            <.button><.icon name="hero-plus" class="size-4" /> Add step</.button>
          </div>
        </.form>
      </section>

      <div
        id="pipeline-steps"
        phx-update="stream"
        class="divide-y divide-base-300 border-y border-base-300"
      >
        <p id="pipeline-steps-empty" class="hidden only:block py-8 text-center text-base-content/60">
          No processing steps configured.
        </p>
        <div
          :for={{id, step} <- @streams.steps}
          id={id}
          class="grid gap-4 py-5 md:grid-cols-[1fr_auto] md:items-center"
        >
          <div>
            <div class="font-medium">{Registry.fetch!(step.implementation_key).label}</div>
            <div class="mt-1 text-sm text-base-content/60">
              Position {step.position + 1} · {if step.enabled, do: "enabled", else: "disabled"} · timeout {step.config[
                "timeout_ms"
              ]} ms
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              id={"move-step-up-#{step.id}"}
              class="btn btn-sm btn-square"
              phx-click="move_step"
              phx-value-id={step.id}
              phx-value-direction="up"
              title="Move up"
            >
              <.icon name="hero-arrow-up" class="size-4" />
            </button>
            <button
              id={"move-step-down-#{step.id}"}
              class="btn btn-sm btn-square"
              phx-click="move_step"
              phx-value-id={step.id}
              phx-value-direction="down"
              title="Move down"
            >
              <.icon name="hero-arrow-down" class="size-4" />
            </button>
            <button
              id={"edit-step-#{step.id}"}
              class="btn btn-sm"
              phx-click="edit_step"
              phx-value-id={step.id}
            >
              Edit
            </button>
            <button
              id={"toggle-step-#{step.id}"}
              class="btn btn-sm"
              phx-click="toggle_step"
              phx-value-id={step.id}
            >
              {if step.enabled, do: "Disable", else: "Enable"}
            </button>
            <button
              id={"delete-step-#{step.id}"}
              class="btn btn-sm btn-error btn-soft"
              phx-click="delete_step"
              phx-value-id={step.id}
              data-confirm="Delete this pipeline step?"
            >
              Delete
            </button>
          </div>

          <.form
            :if={@editing_step_id == step.id}
            for={@edit_form}
            id={"edit-pipeline-step-form-#{step.id}"}
            phx-submit="update_step"
            class="grid gap-4 border-t border-base-300 pt-4 md:col-span-2 md:grid-cols-3"
          >
            <.input
              id={"edit-pipeline-step-enabled-#{step.id}"}
              field={@edit_form[:enabled]}
              type="checkbox"
              label="Enabled"
            />
            <.input
              id={"edit-pipeline-step-timeout-#{step.id}"}
              field={@edit_form[:timeout_ms]}
              type="number"
              label="Timeout (ms)"
            />
            <.input
              id={"edit-pipeline-step-minimum-text-#{step.id}"}
              field={@edit_form[:minimum_text_length]}
              type="number"
              label="Minimum text length"
            />
            <div class="flex gap-2 md:col-span-3">
              <.button>Save</.button>
              <button type="button" class="btn" phx-click="cancel_edit">Cancel</button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_steps(socket) do
    stream(socket, :steps, Processing.list_steps(socket.assigns.feed), reset: true)
  end

  defp assign_new_form(socket) do
    implementation = Registry.all() |> List.first()

    params =
      implementation.default_config
      |> Map.put("implementation_key", implementation.key)

    assign(socket, :form, to_form(params, as: :pipeline_step))
  end

  defp error_message({field, message}), do: "#{field} #{message}"
  defp error_message(%Ecto.Changeset{}), do: "Pipeline step could not be saved"
  defp error_message(reason), do: inspect(reason)
end
