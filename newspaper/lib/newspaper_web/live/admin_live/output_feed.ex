defmodule NewspaperWeb.AdminLive.OutputFeed do
  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav

  alias Ecto.Changeset
  alias Newspaper.{Intake, Pipeline, Processing, Publishing}
  alias Newspaper.Processing.PipelineStep
  alias NewspaperWeb.AdminLive.Format

  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> stream_configure(:batches, dom_id: &"pipeline-batch-#{&1.id}")
     |> assign(:feed_id, String.to_integer(id))
     |> assign(:groups, Intake.list_intake_groups())
     |> assign(:input_feeds, Intake.list_input_feeds())
     |> assign(:rerender_task_ref, nil)
     |> assign(:rerender_pending, false)
     |> assign(:rerendering, false)
     |> assign_feed()
     |> assign_processing()}
  end

  def handle_event("update_feed", %{"generated_feed" => params}, socket) do
    changeset =
      socket.assigns.feed
      |> Publishing.change_generated_feed(params)
      |> validate_rendering_dependencies(socket.assigns)

    if changeset.valid? do
      rendering_changed = rendering_changed?(socket.assigns.feed, changeset)

      case Publishing.update_generated_feed(socket.assigns.feed, params) do
        {:ok, feed} ->
          socket =
            socket
            |> assign_feed(feed)
            |> assign_processing()
            |> put_flash(
              :info,
              if(rendering_changed,
                do: "Output feed saved; re-render started",
                else: "Output feed saved"
              )
            )

          {:noreply, if(rendering_changed, do: start_rerender(socket), else: socket)}

        {:error, changeset} ->
          {:noreply, assign_form_error(socket, changeset, params)}
      end
    else
      {:noreply, assign_form_error(socket, changeset, params)}
    end
  end

  def handle_event("toggle_processing", %{"step-type" => step_type}, socket)
      when step_type in ["extraction", "digestion"] do
    state = processing_state(socket.assigns, step_type)
    enabled = not state.enabled

    with :ok <- validate_processing_toggle(socket.assigns, step_type, enabled),
         {:ok, _step} <-
           persist_processing_toggle(socket.assigns.feed, state.step, step_type, enabled) do
      {:noreply,
       socket
       |> put_flash(:info, processing_toggle_message(step_type, enabled))
       |> assign_processing()}
    else
      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
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

  def handle_event("backfill_feed", _params, socket) do
    feed_id = socket.assigns.feed.id

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Pipeline.backfill_output_feed(feed_id, "manual")
    end)

    {:noreply, put_flash(socket, :info, "Output feed backfill started")}
  end

  def handle_event("rerender_feed", _params, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "Output feed re-render started")
     |> start_rerender()}
  end

  def handle_event("delete_feed", _params, socket) do
    case Publishing.delete_generated_feed(socket.assigns.feed) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Output feed deleted")
         |> push_navigate(to: ~p"/output-feeds")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Output feed could not be deleted")}
    end
  end

  def handle_info({ref, result}, %{assigns: %{rerender_task_ref: ref}} = socket) do
    Process.demonitor(ref, [:flush])

    socket =
      socket
      |> assign(:rerender_task_ref, nil)
      |> assign(:rerendering, false)
      |> assign_processing()

    socket =
      case result do
        {:ok, %{status: "succeeded"}} -> put_flash(socket, :info, "Output feed re-rendered")
        {:ok, _run} -> put_flash(socket, :error, "Output feed re-render completed with failures")
        {:error, _reason} -> put_flash(socket, :error, "Output feed re-render failed")
      end

    if socket.assigns.rerender_pending do
      {:noreply, socket |> assign(:rerender_pending, false) |> start_rerender()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %{assigns: %{rerender_task_ref: ref}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:rerender_task_ref, nil)
     |> assign(:rerender_pending, false)
     |> assign(:rerendering, false)
     |> put_flash(:error, "Output feed re-render stopped: #{inspect(reason)}")}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    case Publishing.get_generated_feed(socket.assigns.feed_id) do
      nil -> {:noreply, push_navigate(socket, to: ~p"/output-feeds")}
      feed -> {:noreply, assign_processing(socket, feed)}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="output-feeds" />

      <header class="mb-7 flex flex-col gap-4 border-b border-base-300 pb-6 lg:flex-row lg:items-end lg:justify-between">
        <div class="min-w-0">
          <.link
            navigate={~p"/output-feeds"}
            class="mb-3 inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Output feeds
          </.link>
          <div class="flex flex-wrap items-center gap-2">
            <h1 id="output-feed-heading" class="text-2xl font-semibold">{@feed.title}</h1>
            <span class={if(@feed.enabled, do: "badge badge-success badge-soft", else: "badge")}>
              {if @feed.enabled, do: "Enabled", else: "Disabled"}
            </span>
            <span :if={@rerendering} id="feed-rerender-status" class="badge badge-warning badge-soft">
              Re-rendering
            </span>
          </div>
          <a
            href={Publishing.feed_url(@feed)}
            target="_blank"
            class="mt-2 inline-flex max-w-full items-center gap-1 truncate text-sm text-primary hover:underline"
          >
            {Publishing.feed_url(@feed)}
            <.icon name="hero-arrow-top-right-on-square" class="size-4 shrink-0" />
          </a>
        </div>
        <div class="flex flex-wrap gap-2">
          <button id="backfill-output-feed" class="btn btn-sm" phx-click="backfill_feed">
            <.icon name="hero-plus-circle" class="size-4" /> Backfill
          </button>
          <button
            id="rerender-output-feed"
            class="btn btn-sm"
            phx-click="rerender_feed"
            disabled={@rerendering}
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-render
          </button>
          <button
            id="delete-output-feed"
            class="btn btn-error btn-soft btn-sm btn-square"
            phx-click="delete_feed"
            data-confirm="Delete this output feed?"
            title="Delete output feed"
            aria-label="Delete output feed"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </header>

      <section
        id="feed-processing-summary"
        class="mb-8 grid border-y border-base-300 sm:grid-cols-3 sm:divide-x sm:divide-base-300"
      >
        <div class="py-4 sm:px-5 sm:first:pl-0">
          <div class="text-2xl font-semibold tabular-nums">{@item_count}</div>
          <div class="text-sm text-base-content/60">Feed articles</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-2xl font-semibold tabular-nums">{@enabled_step_count}</div>
          <div class="text-sm text-base-content/60">Active processing steps</div>
        </div>
        <div class="border-t border-base-300 py-4 sm:border-t-0 sm:px-5">
          <div class="text-sm font-medium">{rendering_label(@feed)}</div>
          <div class="text-sm text-base-content/60">Published content</div>
        </div>
      </section>

      <div class="grid gap-10 xl:grid-cols-[minmax(0,1.35fr)_minmax(22rem,0.8fr)] xl:items-start">
        <main id="processing-workspace" class="min-w-0">
          <div class="mb-3">
            <h2 class="text-lg font-semibold">Processing</h2>
          </div>

          <div class="divide-y divide-base-300 border-y border-base-300">
            <.processing_step
              state={@extraction_state}
              active_batch={@active_batches["extraction"]}
              toggle_disabled={false}
            />
            <.processing_step
              state={@digestion_state}
              active_batch={@active_batches["digestion"]}
              toggle_disabled={digestion_toggle_disabled?(assigns)}
              toggle_title={digestion_toggle_title(assigns)}
              model={@settings.ollama_model}
            />
          </div>

          <section :if={@batch_count > 0} class="mt-9">
            <h2 class="mb-3 text-lg font-semibold">Recent processing</h2>
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
                  <div class="mt-2 text-sm text-base-content/70">{batch_summary(batch)}</div>
                </div>
                <div class="text-sm text-base-content/60 md:text-right">
                  {Format.duration(batch)}
                </div>
              </div>
            </div>
          </section>
        </main>

        <aside class="min-w-0 xl:border-l xl:border-base-300 xl:pl-8">
          <h2 class="mb-3 text-lg font-semibold">Feed settings</h2>
          <.form
            for={@form}
            id="output-feed-settings-form"
            phx-submit="update_feed"
            class="space-y-7"
          >
            <section class="border-y border-base-300 py-5">
              <h3 class="mb-4 text-sm font-semibold uppercase text-base-content/55">General</h3>
              <div class="grid gap-3 sm:grid-cols-2 xl:grid-cols-1 2xl:grid-cols-2">
                <.input id="output-feed-title" field={@form[:title]} label="Title" />
                <.input
                  id="output-feed-item-limit"
                  field={@form[:item_limit]}
                  label="Item limit"
                  type="number"
                />
              </div>
              <.input
                id="output-feed-description"
                field={@form[:description]}
                label="Description"
                type="textarea"
              />
              <.input
                id="output-feed-enabled"
                field={@form[:enabled]}
                label="Feed enabled"
                type="checkbox"
              />
            </section>

            <section>
              <h3 class="mb-4 text-sm font-semibold uppercase text-base-content/55">Publishing</h3>
              <.input
                id="output-feed-hosted-links"
                field={@form[:link_to_hosted_article]}
                label="Use hosted article links"
                type="checkbox"
              />
              <.input
                id="output-feed-title-source"
                field={@form[:title_source]}
                label="Item title"
                type="select"
                options={[
                  {"Original feed title", "original"},
                  {"Article digest title", "digest"}
                ]}
              />
              <.input
                id="output-feed-body-source"
                field={@form[:body_source]}
                label="Item body"
                type="select"
                options={[
                  {"Original feed body", "original_feed"},
                  {"Extracted article", "extracted_content"},
                  {"Article digest summary", "digest_summary"}
                ]}
              />
            </section>

            <section class="border-y border-base-300 py-5">
              <h3 class="mb-4 text-sm font-semibold uppercase text-base-content/55">Sources</h3>
              <.input
                id="output-feed-intake-groups"
                name="generated_feed[intake_group_ids][]"
                label="Included intake groups"
                type="select"
                multiple
                options={Enum.map(@groups, &{&1.name, &1.id})}
                value={@intake_group_ids}
                class="select min-h-28 w-full"
              />
              <.input
                id="output-feed-input-feeds"
                name="generated_feed[input_feed_ids][]"
                label="Included input feeds"
                type="select"
                multiple
                options={Enum.map(@input_feeds, &{&1.name, &1.id})}
                value={@input_feed_ids}
                class="select min-h-28 w-full"
              />
            </section>

            <.button id="save-output-feed-settings" phx-disable-with="Saving...">
              <.icon name="hero-check" class="size-4" /> Save changes
            </.button>
          </.form>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  attr :state, :map, required: true
  attr :active_batch, :any, default: nil
  attr :toggle_disabled, :boolean, default: false
  attr :toggle_title, :string, default: nil
  attr :model, :string, default: nil

  defp processing_step(assigns) do
    ~H"""
    <section id={"processing-#{@state.step_type}"} class="py-5">
      <div class="grid gap-4 md:grid-cols-[minmax(0,1fr)_auto] md:items-start">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{step_label(@state.step_type)}</span>
            <span class={if(@state.enabled, do: "badge badge-success badge-soft", else: "badge")}>
              {if @state.enabled, do: "Enabled", else: "Disabled"}
            </span>
          </div>
          <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm text-base-content/65">
            <span><strong class="tabular-nums">{@state.counts.ready}</strong> ready</span>
            <span>
              <strong class="tabular-nums">{@state.counts.not_requested}</strong> not requested
            </span>
            <span :if={@state.counts.blocked > 0}>
              <strong class="tabular-nums">{@state.counts.blocked}</strong> waiting
            </span>
            <span :if={@state.counts.queued + @state.counts.running > 0}>
              <strong class="tabular-nums">{@state.counts.queued + @state.counts.running}</strong>
              processing
            </span>
            <span :if={@state.counts.failed > 0} class="text-error">
              <strong class="tabular-nums">{@state.counts.failed}</strong> failed
            </span>
          </div>
          <div class="mt-2">
            <.link
              :if={@state.step_type == "extraction"}
              navigate={~p"/sites"}
              class="link text-sm"
            >
              Website policies
            </.link>
            <.link
              :if={@state.step_type == "digestion"}
              navigate={~p"/settings"}
              class="link text-sm"
            >
              {@model || "Configure Ollama model"}
            </.link>
          </div>
        </div>
        <div class="flex flex-col items-start gap-2 md:items-end">
          <.input
            id={"toggle-#{@state.step_type}-processing"}
            name={"processing[#{@state.step_type}]"}
            type="checkbox"
            checked={@state.enabled}
            label={step_toggle_label(@state.step_type)}
            phx-click="toggle_processing"
            phx-value-step-type={@state.step_type}
            disabled={@toggle_disabled}
            title={@toggle_title}
          />
          <button
            id={"process-existing-#{@state.step_type}"}
            type="button"
            class="btn btn-sm"
            phx-click="process_existing"
            phx-value-step-type={@state.step_type}
            phx-disable-with="Queueing..."
            disabled={process_existing_disabled?(@state, @active_batch)}
          >
            <.icon name="hero-play" class="size-4" />
            {process_existing_label(@state, @active_batch)}
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp assign_feed(socket, feed \\ nil) do
    feed = feed || Publishing.get_generated_feed!(socket.assigns.feed_id)
    feed = Publishing.get_generated_feed!(feed.id)

    socket
    |> assign(:feed, feed)
    |> assign(:form, to_form(Publishing.change_generated_feed(feed)))
    |> assign(:intake_group_ids, Enum.map(feed.intake_groups, & &1.id))
    |> assign(:input_feed_ids, Enum.map(feed.input_feeds, & &1.id))
  end

  defp assign_form_error(socket, changeset, params) do
    socket
    |> assign(:form, to_form(changeset))
    |> assign(:intake_group_ids, Map.get(params, "intake_group_ids", []))
    |> assign(:input_feed_ids, Map.get(params, "input_feed_ids", []))
  end

  defp assign_processing(socket) do
    assign_processing(socket, Publishing.get_generated_feed!(socket.assigns.feed.id))
  end

  defp assign_processing(socket, feed) do
    steps = Processing.list_steps(feed)
    counts = Processing.feed_step_counts(feed.id)
    item_count = Publishing.count_items_for_feed(feed)
    batches = Processing.list_feed_batches(feed.id)

    socket
    |> assign(:feed, feed)
    |> assign(:settings, Newspaper.Operations.get_settings())
    |> assign(:item_count, item_count)
    |> assign(:enabled_step_count, Enum.count(steps, & &1.enabled))
    |> assign(:extraction_state, build_processing_state("extraction", steps, counts, item_count))
    |> assign(:digestion_state, build_processing_state("digestion", steps, counts, item_count))
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

  defp build_processing_state(step_type, steps, counts, item_count) do
    step = Enum.find(steps, &(&1.step_type == step_type))

    %{
      step_type: step_type,
      step: step,
      enabled: not is_nil(step) and step.enabled,
      counts:
        if(step,
          do: Map.fetch!(counts, step.id),
          else: %{
            total: item_count,
            ready: 0,
            not_requested: item_count,
            blocked: 0,
            queued: 0,
            running: 0,
            failed: 0,
            skipped: 0
          }
        )
    }
  end

  defp processing_state(assigns, "extraction"), do: assigns.extraction_state
  defp processing_state(assigns, "digestion"), do: assigns.digestion_state

  defp persist_processing_toggle(feed, nil, "extraction", true),
    do: Processing.create_extraction_step(feed)

  defp persist_processing_toggle(feed, nil, "digestion", true),
    do: Processing.create_digest_step(feed)

  defp persist_processing_toggle(_feed, %PipelineStep{} = step, _step_type, enabled),
    do: Processing.update_step(step, %{enabled: enabled})

  defp persist_processing_toggle(_feed, nil, _step_type, false), do: {:ok, nil}

  defp validate_processing_toggle(assigns, "digestion", true) do
    cond do
      not assigns.extraction_state.enabled -> {:error, :extraction_step_required}
      blank?(assigns.settings.ollama_model) -> {:error, :ollama_model_not_configured}
      true -> :ok
    end
  end

  defp validate_processing_toggle(assigns, "digestion", false) do
    if digest_rendering?(assigns.feed) do
      {:error, :digest_rendering_requires_digestion}
    else
      :ok
    end
  end

  defp validate_processing_toggle(assigns, "extraction", false) do
    cond do
      assigns.digestion_state.enabled -> {:error, :digestion_requires_extraction}
      extraction_rendering?(assigns.feed) -> {:error, :rendering_requires_extraction}
      true -> :ok
    end
  end

  defp validate_processing_toggle(_assigns, _step_type, _enabled), do: :ok

  defp validate_rendering_dependencies(changeset, assigns) do
    title_source = Changeset.get_field(changeset, :title_source)
    body_source = Changeset.get_field(changeset, :body_source)
    hosted_links = Changeset.get_field(changeset, :link_to_hosted_article)

    changeset =
      if (title_source == "digest" or body_source == "digest_summary") and
           not assigns.digestion_state.enabled do
        field = if title_source == "digest", do: :title_source, else: :body_source
        Changeset.add_error(changeset, field, "requires article digestion")
      else
        changeset
      end

    if (hosted_links or body_source == "extracted_content" or title_source == "digest" or
          body_source == "digest_summary") and not assigns.extraction_state.enabled do
      field = if hosted_links, do: :link_to_hosted_article, else: :body_source
      Changeset.add_error(changeset, field, "requires article extraction")
    else
      changeset
    end
  end

  defp rendering_changed?(feed, changeset) do
    Enum.any?([:link_to_hosted_article, :title_source, :body_source], fn field ->
      Map.get(feed, field) != Changeset.get_field(changeset, field)
    end)
  end

  defp start_rerender(%{assigns: %{rerender_task_ref: ref}} = socket) when not is_nil(ref) do
    assign(socket, :rerender_pending, true)
  end

  defp start_rerender(socket) do
    feed_id = socket.assigns.feed.id

    task =
      Task.Supervisor.async_nolink(Newspaper.Processing.TaskSupervisor, fn ->
        Pipeline.rerender_output_feed(feed_id, "settings_change")
      end)

    socket
    |> assign(:rerender_task_ref, task.ref)
    |> assign(:rerendering, true)
  end

  defp digestion_toggle_disabled?(assigns) do
    not assigns.digestion_state.enabled and
      (not assigns.extraction_state.enabled or blank?(assigns.settings.ollama_model))
  end

  defp digestion_toggle_title(assigns) do
    cond do
      assigns.digestion_state.enabled -> nil
      not assigns.extraction_state.enabled -> "Enable article extraction first"
      blank?(assigns.settings.ollama_model) -> "Configure an Ollama model first"
      true -> nil
    end
  end

  defp process_existing_disabled?(state, active_batch) do
    not state.enabled or state.counts.not_requested == 0 or not is_nil(active_batch)
  end

  defp process_existing_label(state, nil) do
    if state.step_type == "digestion" and state.counts.not_requested == 0 and
         state.counts.blocked > 0 do
      "Waiting for extraction"
    else
      process_available_label(state.step_type, state.counts.not_requested)
    end
  end

  defp process_existing_label(_state, batch) do
    "Processing #{batch_completed(batch)} of #{batch.summary_counts["total"] || 0}"
  end

  defp process_available_label(_step_type, 0), do: "No existing work"
  defp process_available_label("extraction", 1), do: "Extract 1 existing article"
  defp process_available_label("extraction", count), do: "Extract #{count} existing articles"
  defp process_available_label("digestion", 1), do: "Digest 1 existing article"
  defp process_available_label("digestion", count), do: "Digest #{count} existing articles"

  defp step_label("extraction"), do: "Article extraction"
  defp step_label("digestion"), do: "Article digestion"

  defp step_toggle_label("extraction"), do: "Extract future articles"
  defp step_toggle_label("digestion"), do: "Digest future articles"

  defp processing_toggle_message("extraction", true), do: "Article extraction enabled"
  defp processing_toggle_message("extraction", false), do: "Article extraction disabled"
  defp processing_toggle_message("digestion", true), do: "Article digestion enabled"
  defp processing_toggle_message("digestion", false), do: "Article digestion disabled"

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

  defp digest_rendering?(feed),
    do: feed.title_source == "digest" or feed.body_source == "digest_summary"

  defp extraction_rendering?(feed),
    do: feed.link_to_hosted_article or feed.body_source == "extracted_content"

  defp error_message({:no_enabled_step, step_type}),
    do: "Enable #{step_label(step_type) |> String.downcase()} first"

  defp error_message(:extraction_step_required), do: "Enable article extraction first"
  defp error_message(:ollama_model_not_configured), do: "Choose an Ollama model in Settings first"

  defp error_message(:digest_rendering_requires_digestion),
    do: "Digest title or summary requires article digestion"

  defp error_message(:digestion_requires_extraction),
    do: "Disable article digestion before disabling extraction"

  defp error_message(:rendering_requires_extraction),
    do: "Hosted links or extracted bodies require article extraction"

  defp error_message(%Changeset{}), do: "Processing setting could not be saved"
  defp error_message(reason), do: inspect(reason)

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

  defp blank?(value), do: value in [nil, ""]
end
