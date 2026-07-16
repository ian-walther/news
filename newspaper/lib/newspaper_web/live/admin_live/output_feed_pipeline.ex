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
     |> stream_configure(:batches, dom_id: &"pipeline-batch-#{&1.id}")
     |> assign(:feed, feed)
     |> assign(:editing_step_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:implementations, Registry.all())
     |> assign_new_form()
     |> assign_steps()
     |> assign_processing()}
  end

  def handle_event("create_step", %{"pipeline_step" => params}, socket) do
    case Processing.create_step(socket.assigns.feed, params) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Pipeline step created")
         |> assign_new_form()
         |> assign_steps()
         |> assign_processing()}

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
     |> assign_steps()
     |> assign_processing()}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_step_id, nil)
     |> assign(:edit_form, nil)
     |> assign_steps()
     |> assign_processing()}
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
         |> assign_steps()
         |> assign_processing()}

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
    {:noreply, socket |> assign_steps() |> assign_processing()}
  end

  def handle_event("delete_step", %{"id" => id}, socket) do
    step = Processing.get_step!(String.to_integer(id))
    {:ok, _step} = Processing.delete_step(step)

    {:noreply,
     socket
     |> put_flash(:info, "Pipeline step deleted")
     |> assign_steps()
     |> assign_processing()}
  end

  def handle_event("move_step", %{"id" => id, "direction" => direction}, socket) do
    step = Processing.get_step!(String.to_integer(id))
    direction = if direction == "up", do: :up, else: :down
    {:ok, _step} = Processing.move_step(step, direction)
    {:noreply, socket |> assign_steps() |> assign_processing()}
  end

  def handle_event("process_existing", _params, socket) do
    case Processing.start_feed_batch(socket.assigns.feed.id, "manual") do
      {:ok, batch} ->
        count = batch.summary_counts["total"]

        {:noreply,
         socket
         |> put_flash(:info, "Queued #{count} unprocessed articles")
         |> assign_processing()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, socket |> assign_steps() |> assign_processing()}
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
          disabled={process_existing_disabled?(assigns)}
          class="btn btn-primary"
        >
          <.icon name="hero-play" class="size-4" /> {process_existing_label(assigns)}
        </button>
      </div>

      <section
        id="feed-processing-summary"
        class="mb-8 grid border-y border-base-300 sm:grid-cols-3 sm:divide-x sm:divide-base-300"
      >
        <div class="py-4 sm:px-5 sm:first:pl-0">
          <div class="text-2xl font-semibold tabular-nums">{@processing_counts.items}</div>
          <div class="text-sm text-base-content/60">Feed articles</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-2xl font-semibold tabular-nums">{@processing_counts.extracted}</div>
          <div class="text-sm text-base-content/60">Extracted</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-2xl font-semibold tabular-nums">{@processing_counts.unprocessed}</div>
          <div class="text-sm text-base-content/60">Unprocessed</div>
        </div>
      </section>

      <section :if={@batch_count > 0} class="mb-8">
        <h2 class="mb-3 text-lg font-semibold">Recent Processing</h2>
        <div
          id="pipeline-batches"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div
            :for={{id, batch} <- @streams.batches}
            id={id}
            class="grid gap-3 py-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-center"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{batch_status_label(batch)}</span>
                <span class="text-sm text-base-content/60">{batch.started_at}</span>
              </div>
              <progress
                class="progress progress-primary mt-3 h-2 w-full max-w-xl"
                value={batch_completed(batch)}
                max={max(batch.summary_counts["total"] || 0, 1)}
              >
              </progress>
              <div class="mt-2 text-sm text-base-content/70">
                {batch_summary(batch)}
              </div>
            </div>
            <div class="text-sm text-base-content/60 md:text-right">
              {batch_duration(batch)}
            </div>
          </div>
        </div>
      </section>

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

  defp assign_processing(socket) do
    batches = Processing.list_feed_batches(socket.assigns.feed.id)

    socket
    |> assign(:processing_counts, Processing.feed_processing_counts(socket.assigns.feed.id))
    |> assign(
      :enabled_extraction_steps,
      length(Processing.list_enabled_steps(socket.assigns.feed.id, "extraction"))
    )
    |> assign(:active_batch, Enum.find(batches, &(&1.status == "running")))
    |> assign(:batch_count, length(batches))
    |> stream(:batches, batches, reset: true)
  end

  defp assign_new_form(socket) do
    implementation = Registry.all() |> List.first()

    params =
      implementation.default_config
      |> Map.put("implementation_key", implementation.key)

    assign(socket, :form, to_form(params, as: :pipeline_step))
  end

  defp error_message({field, message}), do: "#{field} #{message}"
  defp error_message(:no_enabled_extraction_step), do: "Add and enable an extraction step first"
  defp error_message(%Ecto.Changeset{}), do: "Pipeline step could not be saved"
  defp error_message(reason), do: inspect(reason)

  defp process_existing_disabled?(assigns) do
    assigns.enabled_extraction_steps == 0 or assigns.processing_counts.unprocessed == 0 or
      not is_nil(assigns.active_batch)
  end

  defp process_existing_label(%{active_batch: batch}) when not is_nil(batch) do
    "Processing #{batch_completed(batch)} of #{batch.summary_counts["total"] || 0}"
  end

  defp process_existing_label(%{enabled_extraction_steps: 0}), do: "Add an extraction step first"

  defp process_existing_label(%{processing_counts: %{unprocessed: 0}}),
    do: "All existing articles processed"

  defp process_existing_label(%{processing_counts: %{unprocessed: 1}}),
    do: "Extract 1 unprocessed article"

  defp process_existing_label(assigns) do
    "Extract #{assigns.processing_counts.unprocessed} unprocessed articles"
  end

  defp batch_completed(batch) do
    (batch.summary_counts["succeeded"] || 0) + (batch.summary_counts["failed"] || 0)
  end

  defp batch_status_label(%{status: "running"}), do: "Processing"

  defp batch_status_label(%{summary_counts: %{"failed" => failed}}) when failed > 0,
    do: "Completed with failures"

  defp batch_status_label(_batch), do: "Completed"

  defp batch_summary(batch) do
    counts = batch.summary_counts

    "#{counts["succeeded"] || 0} succeeded · #{counts["failed"] || 0} failed · " <>
      "#{counts["queued"] || 0} queued · #{counts["running"] || 0} running · " <>
      "#{counts["skipped"] || 0} skipped"
  end

  defp batch_duration(%{finished_at: nil}), do: "In progress"

  defp batch_duration(batch) do
    seconds = max(DateTime.diff(batch.finished_at, batch.started_at, :second), 0)

    cond do
      seconds >= 3600 -> "#{div(seconds, 3600)}h #{div(rem(seconds, 3600), 60)}m"
      seconds >= 60 -> "#{div(seconds, 60)}m #{rem(seconds, 60)}s"
      true -> "#{seconds}s"
    end
  end
end
