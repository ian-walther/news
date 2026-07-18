defmodule NewspaperWeb.AdminLive.OutputFeedPipeline do
  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav

  alias Newspaper.Processing
  alias Newspaper.Publishing
  alias NewspaperWeb.AdminLive.Format

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    feed = Publishing.get_generated_feed!(String.to_integer(id))

    {:ok,
     socket
     |> stream_configure(:batches, dom_id: &"pipeline-batch-#{&1.id}")
     |> assign(:feed, feed)
     |> assign_steps()
     |> assign_processing()}
  end

  def handle_event("enable_extraction", _params, socket) do
    case Processing.create_extraction_step(socket.assigns.feed) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Article extraction enabled")
         |> assign_steps()
         |> assign_processing()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(reason))}
    end
  end

  def handle_event("enable_digestion", _params, socket) do
    case Processing.create_digest_step(socket.assigns.feed) do
      {:ok, _step} ->
        {:noreply,
         socket
         |> put_flash(:info, "Article digestion enabled for future items")
         |> assign_steps()
         |> assign_processing()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
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

  def handle_event("process_existing", %{"step-type" => step_type}, socket) do
    case Processing.start_feed_batch(socket.assigns.feed.id, "manual", step_type) do
      {:ok, batch} ->
        count = batch.summary_counts["total"]

        {:noreply,
         socket
         |> put_flash(
           :info,
           "Queued #{count} #{step_label(step_type) |> String.downcase()} attempts"
         )
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
      <.nav current="output-feeds" />

      <div class="mb-6 flex flex-wrap items-end justify-between gap-3">
        <div>
          <p class="text-sm text-base-content/60">Output feed pipeline</p>
          <h1 class="text-2xl font-semibold">{@feed.title}</h1>
        </div>
        <.link navigate={~p"/output-feeds"} class="btn btn-sm">
          <.icon name="hero-pencil-square" class="size-4" /> Output settings
        </.link>
      </div>

      <section
        id="feed-processing-summary"
        class="mb-8 grid border-y border-base-300 sm:grid-cols-3 sm:divide-x sm:divide-base-300"
      >
        <div class="py-4 sm:px-5 sm:first:pl-0">
          <div class="text-2xl font-semibold tabular-nums">{@item_count}</div>
          <div class="text-sm text-base-content/60">Feed articles</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-2xl font-semibold tabular-nums">{@step_count}</div>
          <div class="text-sm text-base-content/60">Defined steps</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-sm font-medium">{rendering_label(@feed)}</div>
          <div class="text-sm text-base-content/60">Published content</div>
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
                <.local_time
                  id={"pipeline-batch-started-#{batch.id}"}
                  value={batch.started_at}
                  class="text-sm text-base-content/60"
                />
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
              {Format.duration(batch)}
            </div>
          </div>
        </div>
      </section>

      <div class="mb-3 flex items-baseline justify-between gap-4">
        <div>
          <h2 class="text-lg font-semibold">Processing steps</h2>
          <p class="mt-1 text-sm text-base-content/60">
            New articles snapshot enabled steps in this order.
          </p>
        </div>
      </div>

      <div
        id="pipeline-steps"
        phx-update="stream"
        class="mb-6 divide-y divide-base-300 border-y border-base-300"
      >
        <div
          :for={{id, step} <- @streams.steps}
          id={id}
          class="py-5"
        >
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div>
              <div class="flex flex-wrap items-center gap-2">
                <span class="flex size-6 items-center justify-center border border-base-300 text-xs font-semibold">
                  {step.position + 1}
                </span>
                <span class="font-medium">{step_label(step.step_type)}</span>
                <span class={if(step.enabled, do: "badge badge-success badge-soft", else: "badge")}>
                  {if step.enabled, do: "Enabled", else: "Disabled"}
                </span>
              </div>
              <p class="mt-2 text-sm text-base-content/60">{step_description(step.step_type)}</p>
              <.link
                :if={step.step_type == "extraction"}
                navigate={~p"/sites"}
                class="link mt-2 inline-block text-sm"
              >
                Website policies
              </.link>
              <.link
                :if={step.step_type == "digestion"}
                navigate={~p"/settings"}
                class="link mt-2 inline-block text-sm"
              >
                {@settings.ollama_model || "Configure Ollama model"}
              </.link>
            </div>
            <div class="flex flex-wrap gap-2 lg:justify-end">
              <button
                id={"process-existing-#{step.step_type}"}
                type="button"
                class="btn btn-sm btn-primary"
                phx-click="process_existing"
                phx-value-step-type={step.step_type}
                phx-disable-with="Queueing..."
                disabled={process_existing_disabled?(assigns, step)}
              >
                <.icon name="hero-play" class="size-4" />
                {process_existing_label(assigns, step)}
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
                data-confirm="Delete this pipeline step? Existing article history is preserved."
              >
                Delete
              </button>
            </div>
          </div>

          <div class="mt-4 flex flex-wrap gap-x-5 gap-y-2 border-t border-base-200 pt-3 text-sm">
            <span>
              <strong class="tabular-nums">{step_counts(@step_counts, step).ready}</strong> ready
            </span>
            <span>
              <strong class="tabular-nums">{step_counts(@step_counts, step).not_requested}</strong>
              not requested
            </span>
            <span :if={step_counts(@step_counts, step).blocked > 0}>
              <strong class="tabular-nums">{step_counts(@step_counts, step).blocked}</strong> waiting
            </span>
            <span :if={
              step_counts(@step_counts, step).queued + step_counts(@step_counts, step).running > 0
            }>
              <strong class="tabular-nums">
                {step_counts(@step_counts, step).queued + step_counts(@step_counts, step).running}
              </strong>
              processing
            </span>
            <span :if={step_counts(@step_counts, step).failed > 0} class="text-error">
              <strong class="tabular-nums">{step_counts(@step_counts, step).failed}</strong> failed
            </span>
          </div>
        </div>
      </div>

      <section :if={@missing_step_types != []} class="border-y border-base-300 py-5">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h2 class="font-semibold">Add processing step</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Changes apply automatically to future articles.
            </p>
          </div>
          <div class="flex flex-wrap gap-2">
            <button
              :if={"extraction" in @missing_step_types}
              id="enable-extraction-step"
              type="button"
              phx-click="enable_extraction"
              class="btn btn-sm"
            >
              <.icon name="hero-plus" class="size-4" /> Extraction
            </button>
            <button
              :if={"digestion" in @missing_step_types}
              id="enable-digestion-step"
              type="button"
              phx-click="enable_digestion"
              class="btn btn-sm"
              disabled={is_nil(@settings.ollama_model)}
              title={
                if(is_nil(@settings.ollama_model), do: "Configure an Ollama model first", else: nil)
              }
            >
              <.icon name="hero-plus" class="size-4" /> Article digestion
            </button>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end

  defp assign_steps(socket) do
    stream(socket, :steps, Processing.list_steps(socket.assigns.feed), reset: true)
  end

  defp assign_processing(socket) do
    batches = Processing.list_feed_batches(socket.assigns.feed.id)
    steps = Processing.list_steps(socket.assigns.feed)
    step_types = MapSet.new(steps, & &1.step_type)

    socket
    |> assign(:settings, Newspaper.Operations.get_settings())
    |> assign(:item_count, Publishing.list_items_for_feed(socket.assigns.feed) |> length())
    |> assign(:step_count, length(steps))
    |> assign(:step_counts, Processing.feed_step_counts(socket.assigns.feed.id))
    |> assign(
      :missing_step_types,
      Enum.reject(["extraction", "digestion"], &MapSet.member?(step_types, &1))
    )
    |> assign(
      :active_batches,
      Map.new(
        Enum.filter(batches, &(&1.status == "running")),
        &{&1.related["step_type"] || "extraction", &1}
      )
    )
    |> assign(:batch_count, length(batches))
    |> stream(:batches, batches, reset: true)
  end

  defp error_message({:no_enabled_step, step_type}),
    do: "Add and enable #{step_label(step_type) |> String.downcase()} first"

  defp error_message({field, message}), do: "#{field} #{message}"
  defp error_message(:ollama_model_not_configured), do: "Choose an Ollama model in Settings first"
  defp error_message(%Ecto.Changeset{}), do: "Pipeline step could not be saved"
  defp error_message(reason), do: inspect(reason)

  defp process_existing_disabled?(assigns, step) do
    counts = step_counts(assigns.step_counts, step)

    not step.enabled or counts.not_requested == 0 or
      Map.has_key?(assigns.active_batches, step.step_type)
  end

  defp process_existing_label(assigns, step) do
    case Map.get(assigns.active_batches, step.step_type) do
      nil ->
        counts = step_counts(assigns.step_counts, step)

        if step.step_type == "digestion" and counts.not_requested == 0 and counts.blocked > 0 do
          "Waiting for extraction"
        else
          process_available_label(step.step_type, counts.not_requested)
        end

      batch ->
        "Processing #{batch_completed(batch)} of #{batch.summary_counts["total"] || 0}"
    end
  end

  defp process_available_label(_step_type, 0), do: "No existing work"
  defp process_available_label("extraction", 1), do: "Extract 1 existing article"
  defp process_available_label("extraction", count), do: "Extract #{count} existing articles"
  defp process_available_label("digestion", 1), do: "Digest 1 existing article"
  defp process_available_label("digestion", count), do: "Digest #{count} existing articles"

  defp step_counts(counts, step), do: Map.fetch!(counts, step.id)

  defp step_label("extraction"), do: "Article extraction"
  defp step_label("digestion"), do: "Article digestion"
  defp step_label(step_type), do: String.capitalize(step_type)

  defp step_description("extraction"),
    do: "Fetch and normalize full article content using the website's learned extraction policy."

  defp step_description("digestion"),
    do: "Generate one factual replacement title and reading summary from extracted content."

  defp step_description(_step_type), do: "Process article content."

  defp rendering_label(feed) do
    title = if feed.title_source == "digest", do: "Digest title", else: "Original title"

    body =
      case feed.body_source do
        "digest_summary" -> "digest summary"
        "extracted_content" -> "extracted body"
        _body_source -> "original body"
      end

    "#{title} · #{body}"
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
end
