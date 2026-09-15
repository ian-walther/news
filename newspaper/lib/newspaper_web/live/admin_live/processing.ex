defmodule NewspaperWeb.AdminLive.Processing do
  @moduledoc """
  The operational console. Five tabs over one coalesced refresh:

  - Queue (home): live stage cards, running/queued/waiting work, article health
  - Batches: every pipeline batch across feeds, start and cancel
  - Attention: the derived inbox, one action per group
  - Pipeline: per-feed step chains (enable / add / remove / run / retry)
  - History: attempts, operations, and failure records with filters
  """

  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav
  import NewspaperWeb.AdminLive.PipelineChain, only: [feed_chain: 1]

  alias Newspaper.Content
  alias Newspaper.Operations
  alias Newspaper.Operations.Attention
  alias Newspaper.Processing
  alias Newspaper.Processing.Registry
  alias Newspaper.Publishing
  alias NewspaperWeb.AdminLive.Format

  @tabs ~w(queue batches attention pipeline history)
  @stages ~w(all extraction digestion operations)
  @refresh_delay_ms 300
  @tick_ms 30_000

  def mount(_params, _session, socket) do
    if connected?(socket) do
      Newspaper.Events.subscribe()
      Process.send_after(self(), :tick, @tick_ms)
    end

    socket =
      Enum.reduce(Registry.step_types(), socket, fn step_type, socket ->
        stream_configure(socket, :"queued_#{step_type}", dom_id: &"queued-#{step_type}-#{&1.id}")
      end)

    {:ok,
     socket
     |> assign(:refresh_queued, false)
     |> stream_configure(:running_work, dom_id: &"running-#{&1.id}")
     |> stream_configure(:waiting_work, dom_id: &"waiting-#{&1.id}")
     |> stream_configure(:recent_completions, dom_id: &"completed-#{&1.id}")
     |> stream_configure(:recent_work, dom_id: &"recent-#{&1.id}")
     |> stream_configure(:batches, dom_id: &"batch-#{&1.id}")
     |> stream_configure(:failures, dom_id: &"failure-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    context? = params["article_id"] || params["batch_run_id"] || params["stage"]

    filters = %{
      tab: allowed(params["tab"], @tabs, if(context?, do: "history", else: "queue")),
      stage: allowed(params["stage"], @stages, "all"),
      generated_feed_id: parse_id(params["generated_feed_id"]),
      article_id: parse_id(params["article_id"]),
      batch_run_id: parse_id(params["batch_run_id"])
    }

    {:noreply, assign_data(socket, filters)}
  end

  # --- events -----------------------------------------------------------------

  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{socket.assigns.filters | generated_feed_id: parse_id(params["generated_feed_id"])}
    {:noreply, push_patch(socket, to: processing_path(filters))}
  end

  def handle_event("toggle_step", %{"step-id" => step_id}, socket) do
    step = Processing.get_step!(Format.parse_id(step_id))
    label = Registry.step_label(step.step_type)

    case Processing.update_step(step, %{enabled: not step.enabled}) do
      {:ok, updated} ->
        message = "#{label} #{if updated.enabled, do: "enabled", else: "disabled"}"
        {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Format.processing_error_message(reason))}
    end
  end

  def handle_event("add_step", %{"feed-id" => feed_id, "step-type" => step_type}, socket) do
    feed = Publishing.get_generated_feed!(Format.parse_id(feed_id))

    case Processing.create_step(feed, step_type) do
      {:ok, _step} ->
        message = "#{Registry.step_label(step_type)} added to #{feed.title}"
        {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Format.processing_error_message(reason))}
    end
  end

  def handle_event("remove_step", %{"step-id" => step_id}, socket) do
    step = Processing.get_step!(Format.parse_id(step_id))

    case Processing.delete_step(step) do
      {:ok, _step} ->
        message = "#{Registry.step_label(step.step_type)} removed"
        {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Format.processing_error_message(reason))}
    end
  end

  def handle_event("run_existing", %{"feed-id" => feed_id, "step-type" => step_type}, socket) do
    start_batch(socket, Format.parse_id(feed_id), step_type, :not_requested)
  end

  def handle_event("retry_failed", %{"feed-id" => feed_id, "step-type" => step_type}, socket) do
    start_batch(socket, Format.parse_id(feed_id), step_type, :failed)
  end

  def handle_event("start_batch", %{"batch" => params}, socket) do
    selection =
      case params["selection"] do
        "failed" -> :failed
        _selection -> :not_requested
      end

    start_batch(
      socket,
      Format.parse_id(params["generated_feed_id"]),
      params["step_type"],
      selection
    )
  end

  def handle_event("cancel_batch", %{"id" => id}, socket) do
    case Processing.cancel_feed_batch(Format.parse_id(id)) do
      {:ok, result} ->
        cancelled = result.cancelled |> Map.values() |> Enum.sum()

        message =
          case {cancelled, result.running} do
            {0, 0} -> "Nothing left to cancel"
            {n, 0} -> "Cancelled #{n} #{if n == 1, do: "item", else: "items"}"
            {n, r} -> "Cancelled #{n}; #{r} running will finish"
          end

        {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Format.processing_error_message(reason))}
    end
  end

  def handle_event("attention_action", %{"id" => id}, socket) do
    case Map.fetch(socket.assigns.attention_actions, id) do
      {:ok, action} ->
        case Attention.perform(action) do
          {:ok, message} -> {:noreply, socket |> put_flash(:info, message) |> refresh_now()}
          {:error, reason} -> {:noreply, put_flash(socket, :error, attention_error(reason))}
        end

      :error ->
        {:noreply, socket |> put_flash(:error, "That item is no longer listed") |> refresh_now()}
    end
  end

  def handle_event("retry_site_now", %{"host" => host}, socket) do
    {kind, message} =
      case Attention.perform({:try_now, host}) do
        {:ok, message} -> {:info, message}
        {:error, reason} -> {:error, "Could not retry #{host}: #{inspect(reason)}"}
      end

    {:noreply, socket |> put_flash(kind, message) |> refresh_now()}
  end

  def handle_event("toggle_digestion_pause", _params, socket) do
    settings = socket.assigns.settings
    paused = not settings.digestion_paused

    if not paused and not model_configured?(settings) do
      {:noreply, put_flash(socket, :error, "Choose an article digestion model in Settings first")}
    else
      case Operations.update_settings(settings, %{digestion_paused: paused}) do
        {:ok, _settings} ->
          message =
            if paused,
              do: "Article digestion paused; active work will finish",
              else: "Article digestion resumed"

          {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Digestion setting could not be saved")}
      end
    end
  end

  # --- live refresh -----------------------------------------------------------

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, queue_refresh(socket)}
  end

  def handle_info(:refresh_processing_data, socket) do
    {:noreply, socket |> assign(:refresh_queued, false) |> refresh_now()}
  end

  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, refresh_now(socket)}
  end

  defp queue_refresh(%{assigns: %{refresh_queued: true}} = socket), do: socket

  defp queue_refresh(socket) do
    Process.send_after(self(), :refresh_processing_data, @refresh_delay_ms)
    assign(socket, :refresh_queued, true)
  end

  defp refresh_now(socket), do: assign_data(socket, socket.assigns.filters)

  # --- render -----------------------------------------------------------------

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="processing" attention_count={@attention_count} />

      <header class="mb-5">
        <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Operations
        </p>
        <h1 class="text-2xl font-semibold">Processing</h1>
        <p class="mt-1 text-sm text-base-content/65">
          Live pipeline work, batches, what needs attention, configuration, and history.
        </p>
      </header>

      <nav
        id="processing-tabs"
        class="mb-6 flex gap-1 overflow-x-auto border-b border-base-300"
        aria-label="Processing sections"
      >
        <.link
          :for={{label, tab} <- tab_options()}
          id={"processing-tab-#{tab}"}
          patch={processing_path(%{@filters | tab: tab})}
          aria-current={if(@filters.tab == tab, do: "page", else: nil)}
          class={[
            "flex shrink-0 items-center gap-2 px-4 py-2 text-sm",
            @filters.tab == tab && "border-b-2 border-base-content font-semibold",
            @filters.tab != tab && "text-base-content/60 hover:text-base-content"
          ]}
        >
          {label}
          <span
            :if={tab == "attention" && @attention_count > 0}
            id="attention-tab-badge"
            class="badge badge-error badge-sm tabular-nums"
          >
            {@attention_count}
          </span>
        </.link>
      </nav>

      <%= case @filters.tab do %>
        <% "queue" -> %>
          <.queue_tab
            settings={@settings}
            stage_cards={@stage_cards}
            article_stats={@article_stats}
            streams={@streams}
            running_count={@running_count}
            waiting_count={@waiting_count}
          />
        <% "batches" -> %>
          <.batches_tab
            batch_form={@batch_form}
            feed_options={@feed_options}
            step_type_options={@step_type_options}
            selection_options={@selection_options}
            streams={@streams}
            filters={@filters}
          />
        <% "attention" -> %>
          <.attention_tab groups={@attention_groups} />
        <% "pipeline" -> %>
          <.pipeline_tab pipeline={@pipeline} settings={@settings} filters={@filters} />
        <% "history" -> %>
          <.history_tab
            filters={@filters}
            filter_form={@filter_form}
            output_options={@output_options}
            streams={@streams}
          />
      <% end %>
    </Layouts.app>
    """
  end

  defp tab_options,
    do: [
      {"Queue", "queue"},
      {"Batches", "batches"},
      {"Attention", "attention"},
      {"Pipeline", "pipeline"},
      {"History", "history"}
    ]

  # --- Queue tab --------------------------------------------------------------

  attr :settings, :map, required: true
  attr :stage_cards, :list, required: true
  attr :article_stats, :map, required: true
  attr :streams, :map, required: true
  attr :running_count, :integer, required: true
  attr :waiting_count, :integer, required: true

  defp queue_tab(assigns) do
    ~H"""
    <section id="queue-tab">
      <p id="article-health" class="mb-5 text-sm text-base-content/65">
        <span class="font-medium text-base-content">{@article_stats.total}</span>
        {if @article_stats.total == 1, do: "article", else: "articles"} ·
        <span class="tabular-nums">{@article_stats.extracted}</span>
        extracted
        · <span class="tabular-nums">{@article_stats.failed}</span>
        failed extraction
        · <span class="tabular-nums">{@article_stats.skipped}</span>
        no content
        · <span class="tabular-nums">{@article_stats.not_requested}</span>
        not requested <.link navigate={~p"/articles"} class="link ml-1">Articles</.link>
      </p>

      <div id="stage-cards" class="grid gap-px border border-base-300 bg-base-300 lg:grid-cols-2">
        <.stage_card :for={card <- @stage_cards} card={card} settings={@settings} />
      </div>

      <section class="py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Running now</h2>
          <span class="text-xs text-base-content/45">{@running_count} · executions</span>
        </div>
        <div
          id="running-work"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div id="running-work-empty" class="hidden py-7 text-sm text-base-content/55 only:block">
            Nothing is running right now.
          </div>
          <.work_row :for={{dom_id, entry} <- @streams.running_work} id={dom_id} entry={entry} />
        </div>
      </section>

      <section class="border-t border-base-300 py-8">
        <h2 class="mb-4 text-lg font-semibold">Queued next</h2>
        <div class="grid gap-8 xl:grid-cols-2 xl:divide-x xl:divide-base-300">
          <div
            :for={card <- @stage_cards}
            class="min-w-0 xl:[&:nth-child(even)]:pl-8 xl:[&:nth-child(odd)]:pr-8"
          >
            <div class="mb-3 flex items-center justify-between gap-3">
              <div class="flex items-center gap-2">
                <h3 class="font-medium">
                  {card.label}{if card.step_type == "extraction", do: " by website", else: ""}
                </h3>
                <span
                  :if={card.step_type == "digestion" && @settings.digestion_paused}
                  id="digestion-queue-state"
                  class="badge badge-warning badge-soft badge-sm"
                >
                  Paused
                </span>
              </div>
              <span class="text-sm tabular-nums text-base-content/55">{card.queued}</span>
            </div>
            <div
              id={"queued-#{card.step_type}"}
              phx-update="stream"
              class="divide-y divide-base-300 border-y border-base-300"
            >
              <div
                id={"queued-#{card.step_type}-empty"}
                class="hidden py-6 text-sm text-base-content/55 only:block"
              >
                No {String.downcase(card.label)} work is queued.
              </div>
              <.queue_row
                :for={{dom_id, entry} <- Map.fetch!(@streams, :"queued_#{card.step_type}")}
                id={dom_id}
                entry={entry}
              />
            </div>
          </div>
        </div>
      </section>

      <section class="border-t border-base-300 py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Waiting</h2>
          <span class="text-xs text-base-content/45">
            {@waiting_count} · delays and prerequisites
          </span>
        </div>
        <div
          id="waiting-work"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div id="waiting-work-empty" class="hidden py-7 text-sm text-base-content/55 only:block">
            Nothing is waiting on a delay or prerequisite.
          </div>
          <.waiting_row :for={{dom_id, entry} <- @streams.waiting_work} id={dom_id} entry={entry} />
        </div>
      </section>

      <section id="recent-completions" class="border-t border-base-300 py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Just finished</h2>
          <.link
            id="recently-processed-link"
            navigate={~p"/articles?#{%{sort: "recent"}}"}
            class="link text-xs"
          >
            Recently processed articles
          </.link>
        </div>
        <div
          id="recent-completions-list"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div
            id="recent-completions-empty"
            class="hidden py-6 text-sm text-base-content/55 only:block"
          >
            No executions have finished yet.
          </div>
          <div
            :for={{dom_id, entry} <- @streams.recent_completions}
            id={dom_id}
            class="grid gap-2 py-3 text-sm md:grid-cols-[8rem_minmax(0,1fr)_10rem] md:items-center"
          >
            <span class={stage_badge_class(entry.attempt.step_type)}>
              {stage_label(entry.attempt.step_type)}
            </span>
            <.link
              navigate={~p"/articles/#{entry.attempt.article.guid}"}
              class="truncate font-medium hover:underline"
            >
              {entry.attempt.article.title || "Untitled"}
            </.link>
            <.local_time
              id={"completed-time-#{entry.attempt.id}"}
              value={entry.attempt.finished_at}
              class="text-xs text-base-content/55 md:text-right"
            />
          </div>
        </div>
      </section>
    </section>
    """
  end

  attr :card, :map, required: true
  attr :settings, :map, required: true

  defp stage_card(assigns) do
    ~H"""
    <article id={"stage-card-#{@card.step_type}"} class="bg-base-100 p-5">
      <div class="flex flex-wrap items-start justify-between gap-3">
        <div>
          <h2 class="text-base font-semibold">{@card.label}</h2>
          <p class="mt-1 text-xs text-base-content/50">
            Counts executions · {Format.throughput_label(@card.throughput)}
          </p>
        </div>
        <div :if={@card.step_type == "digestion"} class="flex items-center gap-2">
          <span
            id="digestion-runtime-status"
            data-state={if(@settings.digestion_paused, do: "paused", else: "running")}
            class={[
              "badge badge-soft",
              if(@settings.digestion_paused, do: "badge-warning", else: "badge-success")
            ]}
          >
            {if @settings.digestion_paused, do: "Paused", else: "Running"}
          </span>
          <button
            id="toggle-digestion-pause"
            type="button"
            class="btn btn-sm"
            phx-click="toggle_digestion_pause"
            disabled={@settings.digestion_paused && not model_configured?(@settings)}
            title={
              if(@settings.digestion_paused && not model_configured?(@settings),
                do: "Choose a model in Settings before resuming",
                else: nil
              )
            }
          >
            <.icon
              name={if(@settings.digestion_paused, do: "hero-play", else: "hero-pause")}
              class="size-4"
            />
            {if @settings.digestion_paused, do: "Resume digestion", else: "Pause digestion"}
          </button>
        </div>
      </div>

      <dl class="mt-4 grid grid-cols-3 gap-3 text-sm">
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Queued</dt>
          <dd class="mt-1 text-2xl font-semibold tabular-nums">{@card.queued}</dd>
        </div>
        <div>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Running</dt>
          <dd class="mt-1 text-2xl font-semibold tabular-nums">{@card.running}</dd>
        </div>
        <div :if={@card.step_type == "extraction"}>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Held by sites</dt>
          <dd class="mt-1 text-2xl font-semibold tabular-nums">{@card.held}</dd>
        </div>
        <div :if={@card.step_type == "digestion"}>
          <dt class="text-xs font-semibold uppercase text-base-content/45">Model</dt>
          <dd class="mt-1 truncate text-sm font-medium" title={@card.model}>
            {@card.model || "Not configured"}
          </dd>
        </div>
      </dl>

      <p :if={@card.eta} id={"stage-eta-#{@card.step_type}"} class="mt-3 text-sm text-base-content/65">
        {@card.queued} queued · {@card.eta}
      </p>

      <div :if={@card.step_type == "extraction" && @card.hosts != []} class="mt-4">
        <p class="mb-2 text-xs font-semibold uppercase text-base-content/45">Websites</p>
        <ul id="extraction-hosts" class="divide-y divide-base-300 border-y border-base-300 text-sm">
          <li
            :for={host <- @card.hosts}
            id={"host-#{host.slug}"}
            data-state={host.state}
            class="flex flex-wrap items-center justify-between gap-2 py-2"
          >
            <div class="min-w-0">
              <span class="font-medium">{host.host}</span>
              <span class="ml-2 text-xs text-base-content/55">{host.detail}</span>
            </div>
            <div class="flex items-center gap-3">
              <span class="text-xs tabular-nums text-base-content/55">
                {host.count} queued
              </span>
              <button
                :if={host.try_now?}
                id={"retry-site-now-#{host.policy_id}"}
                type="button"
                class="btn btn-xs"
                phx-click="retry_site_now"
                phx-value-host={host.host}
                phx-disable-with="Trying..."
              >
                Try now
              </button>
            </div>
          </li>
        </ul>
      </div>
    </article>
    """
  end

  # --- Batches tab ------------------------------------------------------------

  attr :batch_form, :any, required: true
  attr :feed_options, :list, required: true
  attr :step_type_options, :list, required: true
  attr :selection_options, :list, required: true
  attr :streams, :map, required: true
  attr :filters, :map, required: true

  defp batches_tab(assigns) do
    ~H"""
    <section id="batches-tab">
      <div class="flex flex-col gap-4 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
        <p class="max-w-2xl text-sm text-base-content/65">
          A batch runs one step over a selection of one feed's items. Progress counts the
          batch's own members; work shared with another feed still counts once here.
          Cancelling withdraws unstarted members and lets running work finish.
        </p>
        <.form
          for={@batch_form}
          id="start-batch-form"
          phx-submit="start_batch"
          class="flex flex-wrap items-end gap-2"
        >
          <.input
            field={@batch_form[:generated_feed_id]}
            type="select"
            label="Feed"
            prompt="Choose a feed"
            options={@feed_options}
          />
          <.input
            field={@batch_form[:step_type]}
            type="select"
            label="Step"
            options={@step_type_options}
          />
          <.input
            field={@batch_form[:selection]}
            type="select"
            label="Items"
            options={@selection_options}
          />
          <.button id="start-batch-submit" phx-disable-with="Queueing...">Start batch</.button>
        </.form>
      </div>

      <div id="batches" phx-update="stream" class="divide-y divide-base-300 border-b border-base-300">
        <p id="batches-empty" class="hidden py-10 text-center text-sm text-base-content/55 only:block">
          No batches have run yet. Start one above or from a Pipeline row.
        </p>
        <article
          :for={{dom_id, entry} <- @streams.batches}
          id={dom_id}
          data-status={entry.batch.status}
          class="grid gap-3 py-5 lg:grid-cols-[minmax(0,1fr)_14rem_auto] lg:items-center"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class={Format.status_badge_class(entry.batch.status)}>
                {Format.status_label(entry.batch.status)}
              </span>
              <span class="font-medium">{entry.feed_title}</span>
              <span class="text-sm text-base-content/60">
                {entry.step_label} · {entry.selection_label}
              </span>
            </div>
            <p class="mt-2 text-sm text-base-content/70">
              <%= if entry.batch.status == "running" do %>
                <span id={"batch-progress-#{entry.batch.id}"} class="tabular-nums">
                  {Format.progress_summary(entry.progress)}
                </span>
              <% else %>
                {Format.run_summary(entry.batch)}
              <% end %>
            </p>
            <p :if={entry.batch.error_summary} class="mt-1 text-sm text-error">
              {entry.batch.error_summary}
            </p>
          </div>
          <div class="text-xs text-base-content/55">
            <.local_time id={"batch-started-#{entry.batch.id}"} value={entry.batch.started_at} />
            <p class="mt-1">
              {Format.duration(entry.batch)} · {Format.run_type_label(entry.batch.trigger)}
            </p>
          </div>
          <div class="flex flex-wrap gap-2 lg:justify-end">
            <.link
              id={"batch-attempts-#{entry.batch.id}"}
              patch={
                processing_path(%{
                  @filters
                  | tab: "history",
                    batch_run_id: entry.batch.id,
                    stage: entry.batch.related["step_type"] || "all"
                })
              }
              class="btn btn-ghost btn-sm"
            >
              Attempts
            </.link>
            <button
              :if={entry.batch.status == "running"}
              id={"cancel-batch-#{entry.batch.id}"}
              type="button"
              class="btn btn-error btn-soft btn-sm"
              phx-click="cancel_batch"
              phx-value-id={entry.batch.id}
              phx-disable-with="Cancelling..."
              data-confirm="Cancel this batch? Unstarted items are withdrawn; running work finishes."
            >
              Cancel
            </button>
          </div>
        </article>
      </div>
    </section>
    """
  end

  # --- Attention tab ----------------------------------------------------------

  attr :groups, :list, required: true

  defp attention_tab(assigns) do
    ~H"""
    <section id="attention-tab">
      <p class="mb-5 max-w-2xl text-sm text-base-content/65">
        Derived from current state, grouped by cause. Fixing the cause clears the group;
        nothing here is filed or acknowledged.
      </p>
      <div id="attention-groups" class="divide-y divide-base-300 border-y border-base-300">
        <p
          :if={@groups == []}
          id="attention-empty"
          class="py-10 text-center text-sm text-base-content/55"
        >
          Nothing needs attention.
        </p>
        <article
          :for={group <- @groups}
          id={"attention-#{group.id}"}
          data-kind={group.kind}
          class="grid gap-3 py-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class={stage_badge_class(group.stage)}>{stage_label(group.stage)}</span>
              <span class="font-medium">{group.title}</span>
              <span class="text-sm text-base-content/60">· {group.subject}</span>
              <span class="badge badge-ghost badge-sm tabular-nums">
                {group.count} {if group.count == 1, do: "item", else: "items"}
              </span>
            </div>
            <p :if={group.detail} class="mt-2 truncate text-sm text-base-content/70">
              {group.detail}
            </p>
            <p class="mt-1 text-xs text-base-content/50">{group.note}</p>
            <details :if={group.items != []} class="mt-3 text-sm">
              <summary class="cursor-pointer text-xs font-medium text-base-content/60 hover:text-base-content">
                Show items
              </summary>
              <ul class="mt-2 divide-y divide-base-300 border-y border-base-300">
                <li
                  :for={item <- group.items}
                  id={"attention-item-#{group.id}-#{item.id}"}
                  class="flex items-center justify-between gap-3 py-2"
                >
                  <span class="min-w-0 truncate text-base-content/75">{item.label}</span>
                  <button
                    :if={item.action_id}
                    type="button"
                    class="btn btn-ghost btn-xs shrink-0"
                    phx-click="attention_action"
                    phx-value-id={item.action_id}
                  >
                    Re-run
                  </button>
                </li>
              </ul>
            </details>
          </div>
          <div class="lg:text-right">
            <button
              :if={group.action}
              id={"attention-action-#{group.id}"}
              type="button"
              class="btn btn-sm"
              phx-click="attention_action"
              phx-value-id={group.id}
              phx-disable-with="Working..."
            >
              {group.action_label}
            </button>
            <span :if={is_nil(group.action)} class="text-xs text-base-content/50">
              {group.action_label}
            </span>
          </div>
        </article>
      </div>
    </section>
    """
  end

  # --- Pipeline tab -----------------------------------------------------------

  attr :pipeline, :list, required: true
  attr :settings, :map, required: true
  attr :filters, :map, required: true

  defp pipeline_tab(assigns) do
    ~H"""
    <section id="pipeline-tab">
      <div class="flex flex-col gap-4 border-b border-base-300 pb-5 lg:flex-row lg:items-end lg:justify-between">
        <p class="max-w-2xl text-sm text-base-content/65">
          Each feed runs its steps in order. An item does not reach a step until every step
          before it is ready or skipped, so a queued or failed link explains why the links
          after it are waiting. Step order is fixed; enable, add, or remove steps here.
        </p>
        <.link
          id="pipeline-start-batch"
          patch={processing_path(%{@filters | tab: "batches"})}
          class="btn btn-sm"
        >
          Start batch…
        </.link>
      </div>

      <section class="mt-6">
        <div class="flex items-baseline gap-3">
          <h2 class="text-base font-semibold">Source enrichment</h2>
          <span class="text-xs text-base-content/50">
            one chain per source · not yet available
          </span>
        </div>
        <p
          id="source-enrichment-empty"
          class="mt-2 border border-dashed border-base-300 px-4 py-3 text-sm text-base-content/50"
        >
          No source-scoped steps exist yet. Extraction moves here, one chain per outlet, when
          upstream enrichment lands.
        </p>
      </section>

      <section class="mt-8">
        <div class="flex items-baseline gap-3">
          <h2 class="text-base font-semibold">Output processing</h2>
          <span class="text-xs text-base-content/50">
            one chain per output feed · counts output item steps
          </span>
        </div>
        <div id="pipeline-feeds" class="mt-2 divide-y divide-base-300 border-y border-base-300">
          <p :if={@pipeline == []} class="py-8 text-center text-sm text-base-content/55">
            No output feeds match this filter.
          </p>
          <.feed_chain :for={entry <- @pipeline} entry={entry} settings={@settings} />
        </div>
      </section>
    </section>
    """
  end

  # --- History tab ------------------------------------------------------------

  attr :filters, :map, required: true
  attr :filter_form, :any, required: true
  attr :output_options, :list, required: true
  attr :streams, :map, required: true

  defp history_tab(assigns) do
    ~H"""
    <section id="history-tab">
      <section class="border-y border-base-300 py-4">
        <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_18rem] lg:items-end">
          <div>
            <p class="mb-2 text-xs font-semibold uppercase text-base-content/45">Stage</p>
            <nav class="join max-w-full overflow-x-auto" aria-label="Processing stage">
              <.link
                :for={{label, stage} <- stage_options()}
                id={"processing-stage-#{stage}"}
                patch={processing_path(%{@filters | stage: stage})}
                class={[
                  "join-item btn btn-sm shrink-0",
                  @filters.stage == stage && "btn-active"
                ]}
              >
                {label}
              </.link>
            </nav>
          </div>

          <.form for={@filter_form} id="processing-filter" phx-change="filter">
            <.input
              field={@filter_form[:generated_feed_id]}
              type="select"
              label="Output feed"
              options={@output_options}
            />
          </.form>
        </div>

        <div
          :if={@filters.article_id || @filters.batch_run_id}
          id="processing-context"
          class="mt-4 flex flex-wrap items-center justify-between gap-3 border-t border-base-300 pt-4"
        >
          <div class="flex flex-wrap items-center gap-2 text-sm">
            <span class="font-medium">Focused context</span>
            <span :if={@filters.article_id} class="badge badge-outline">
              Article #{@filters.article_id}
            </span>
            <span :if={@filters.batch_run_id} class="badge badge-outline">
              Batch #{@filters.batch_run_id}
            </span>
          </div>
          <.link
            id="clear-processing-context"
            patch={processing_path(%{@filters | article_id: nil, batch_run_id: nil})}
            class="btn btn-ghost btn-sm"
          >
            <.icon name="hero-x-mark" class="size-4" /> Clear
          </.link>
        </div>
      </section>

      <section class="py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Work</h2>
          <span class="text-xs text-base-content/45">Newest first · executions and operations</span>
        </div>
        <div
          id="recent-work"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div id="recent-work-empty" class="hidden py-7 text-sm text-base-content/55 only:block">
            No work matches these filters.
          </div>
          <.work_row :for={{dom_id, entry} <- @streams.recent_work} id={dom_id} entry={entry} />
        </div>
      </section>

      <section :if={@filters.stage in ["all", "operations"]} class="border-t border-base-300 py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Failure records</h2>
          <span class="text-xs text-base-content/45">
            Historical · resolved records stay listed
          </span>
        </div>
        <div
          id="failure-records"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div id="failure-records-empty" class="hidden py-7 text-sm text-base-content/55 only:block">
            No failure records.
          </div>
          <article
            :for={{dom_id, failure} <- @streams.failures}
            id={dom_id}
            data-resolved={to_string(not is_nil(failure.resolved_at))}
            class="grid gap-2 py-4 md:grid-cols-[minmax(0,1fr)_10rem] md:items-start"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <span class="font-medium">{Format.failure_type_label(failure.failure_type)}</span>
                <span :if={failure.resolved_at} class="badge badge-success badge-soft badge-sm">
                  Resolved
                </span>
                <span :if={failure.retry_count > 0} class="text-xs text-base-content/50">
                  retried {failure.retry_count}×
                </span>
              </div>
              <p class="mt-1 truncate text-sm text-base-content/70">{failure.message}</p>
              <p :if={failure.related["url"]} class="mt-1 truncate text-xs text-base-content/50">
                {failure.related["url"]}
              </p>
            </div>
            <.local_time
              id={"failure-time-#{failure.id}"}
              value={failure.inserted_at}
              class="text-xs text-base-content/55 md:text-right"
            />
          </article>
        </div>
      </section>
    </section>
    """
  end

  # --- shared rows ------------------------------------------------------------

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp work_row(%{entry: %{kind: :attempt}} = assigns) do
    ~H"""
    <article id={@id} class="grid gap-3 py-5 lg:grid-cols-[10rem_minmax(0,1fr)_10rem]">
      <div>
        <span class={stage_badge_class(@entry.attempt.step_type)}>
          {stage_label(@entry.attempt.step_type)}
        </span>
        <p class="mt-2 text-xs text-base-content/45">Attempt #{@entry.attempt.id}</p>
      </div>
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class={Format.work_status_badge_class(@entry.attempt.status)}>
            {Format.work_status_label(@entry.attempt.status)}
          </span>
          <span class="text-xs text-base-content/50">{Format.duration(@entry.attempt)}</span>
          <span :if={@entry.host} class="text-xs text-base-content/50">{@entry.host}</span>
          <span :if={retry_label(@entry.attempt)} class="badge badge-warning badge-soft badge-sm">
            {retry_label(@entry.attempt)}
          </span>
        </div>
        <p class="mt-2 truncate font-medium">{@entry.attempt.article.title || "Untitled"}</p>
        <p class="mt-1 truncate text-sm text-base-content/55">{feed_titles(@entry)}</p>
        <p :if={@entry.attempt.error_message} class="mt-2 text-sm text-error">
          {@entry.attempt.error_message}
        </p>
        <div class="mt-3 flex flex-wrap gap-2">
          <.link
            patch={
              processing_path(%{
                @entry.filters
                | tab: "history",
                  article_id: @entry.attempt.article_id
              })
            }
            class="link text-xs"
          >
            Article context
          </.link>
          <.link
            :if={@entry.attempt.batch_run_id}
            patch={
              processing_path(%{
                @entry.filters
                | tab: "history",
                  batch_run_id: @entry.attempt.batch_run_id
              })
            }
            class="link text-xs"
          >
            Batch #{@entry.attempt.batch_run_id}
          </.link>
        </div>
        <details :if={@entry.attempt.runs != []} class="mt-3 text-xs text-base-content/60">
          <summary class="cursor-pointer font-medium hover:text-base-content">
            {length(@entry.attempt.runs)} execution {if length(@entry.attempt.runs) == 1,
              do: "run",
              else: "runs"}
          </summary>
          <div class="mt-2 divide-y divide-base-300 border-y border-base-300">
            <div :for={run <- Enum.sort_by(@entry.attempt.runs, & &1.started_at, :desc)} class="py-2">
              <span class="font-medium">Run #{run.id}</span>
              <span class="ml-2">{Format.status_label(run.status)}</span>
              <span class="ml-2">{Format.duration(run)}</span>
              <p :if={run.error_summary} class="mt-1 text-error">{run.error_summary}</p>
            </div>
          </div>
        </details>
      </div>
      <div class="text-xs text-base-content/55 lg:text-right">
        <.local_time id={"attempt-time-#{@entry.attempt.id}"} value={entry_time(@entry)} />
        <p class="mt-1">{attempt_implementation(@entry.attempt)}</p>
      </div>
    </article>
    """
  end

  defp work_row(%{entry: %{kind: :operation}} = assigns) do
    ~H"""
    <article id={@id} class="grid gap-3 py-5 lg:grid-cols-[10rem_minmax(0,1fr)_10rem]">
      <div>
        <span class="badge badge-outline">Operation</span>
        <p class="mt-2 text-xs text-base-content/45">Run #{@entry.run.id}</p>
      </div>
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-2">
          <span class={Format.status_badge_class(@entry.run.status)}>
            {Format.status_label(@entry.run.status)}
          </span>
          <span class="text-xs text-base-content/50">{Format.duration(@entry.run)}</span>
          <span class="text-xs text-base-content/45">
            {Format.run_type_label(@entry.run.trigger)}
          </span>
        </div>
        <p class="mt-2 font-medium">{operation_label(@entry.run)}</p>
        <p class="mt-1 text-sm text-base-content/55">{Format.run_subject(@entry.context)}</p>
        <p class="mt-2 text-sm text-base-content/70">{Format.run_summary(@entry.context)}</p>
        <p :if={@entry.run.error_summary} class="mt-2 text-sm text-error">
          {@entry.run.error_summary}
        </p>
        <.link
          :if={@entry.run.run_type == "pipeline_batch"}
          patch={processing_path(%{@entry.filters | tab: "history", batch_run_id: @entry.run.id})}
          class="mt-3 inline-block link text-xs"
        >
          Batch attempts
        </.link>
        <details class="mt-3 text-xs text-base-content/60">
          <summary class="cursor-pointer font-medium hover:text-base-content">Debug details</summary>
          <pre class="mt-2 max-h-72 max-w-full overflow-auto whitespace-pre-wrap break-all bg-base-200 p-3 text-[0.7rem] leading-relaxed"><%= inspect(%{
              related: @entry.run.related,
              summary: @entry.run.summary_counts,
              metadata: @entry.run.debug_metadata
            }, pretty: true) %></pre>
        </details>
      </div>
      <div class="text-xs text-base-content/55 lg:text-right">
        <.local_time id={"run-time-#{@entry.run.id}"} value={@entry.run.started_at} />
        <p :if={@entry.run.finished_at} class="mt-1">Finished</p>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp queue_row(assigns) do
    ~H"""
    <article id={@id} class="grid grid-cols-[2.25rem_minmax(0,1fr)] gap-3 py-4">
      <span class="grid size-8 place-items-center border border-base-300 text-xs font-semibold tabular-nums">
        {@entry.position}
      </span>
      <div class="min-w-0">
        <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
          <span class="truncate text-sm font-medium">
            {@entry.attempt.article.title || "Untitled"}
          </span>
          <span :if={@entry.host} class="text-xs text-base-content/50">{@entry.host}</span>
        </div>
        <p class="mt-1 truncate text-xs text-base-content/50">{feed_titles(@entry)}</p>
        <div class="mt-2 flex flex-wrap gap-2 text-xs text-base-content/45">
          <span>
            Queued {Format.duration(%{started_at: @entry.attempt.inserted_at, finished_at: nil})}
          </span>
          <span :if={retry_label(@entry.attempt)} class="text-warning">
            {retry_label(@entry.attempt)}
          </span>
          <span :if={@entry.wait_label} class="text-warning">{@entry.wait_label}</span>
        </div>
      </div>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true

  defp waiting_row(assigns) do
    ~H"""
    <article id={@id} class="grid gap-2 py-4 md:grid-cols-[12rem_minmax(0,1fr)_auto] md:items-center">
      <div class="flex items-center gap-2">
        <span class={stage_badge_class(@entry.stage)}>{stage_label(@entry.stage)}</span>
        <span class="truncate text-sm font-medium">{@entry.subject}</span>
      </div>
      <p class="text-sm text-base-content/60">{@entry.reason}</p>
      <span class="text-sm tabular-nums text-base-content/55 md:text-right">
        {@entry.count} {if @entry.count == 1, do: "item", else: "items"}
      </span>
    </article>
    """
  end

  # --- data -------------------------------------------------------------------

  defp assign_data(socket, filters) do
    socket
    |> assign(:filters, filters)
    |> assign(:settings, Operations.get_settings())
    |> assign(:attention_count, Attention.count())
    |> assign_tab_data(filters)
  end

  defp assign_tab_data(socket, %{tab: "queue"} = filters) do
    policies = Content.list_site_extraction_policies() |> Map.new(&{&1.site_host, &1})
    running_attempts = Processing.list_processing_attempts(["running"], limit: 250)
    queued_attempts = Processing.list_processing_attempts(["queued"], limit: 5_000)
    waiting_steps = Processing.list_waiting_item_steps(limit: 250)
    attempt_counts = Processing.processing_attempt_counts()
    waiting_counts = Processing.waiting_item_step_counts()

    running_operations =
      Operations.list_processing_run_entries(limit: 100)
      |> Enum.filter(&(&1.run.status == "running"))

    running_work =
      Enum.map(running_attempts, &attempt_entry(&1, filters, policies)) ++
        Enum.map(running_operations, &operation_entry(&1, filters))

    queued_by_type =
      Map.new(Registry.step_types(), fn step_type ->
        {step_type, queue_entries(queued_attempts, step_type, filters, policies)}
      end)

    waiting_work =
      delayed_site_entries(queued_by_type["extraction"] || [], running_attempts, policies) ++
        blocked_entries(waiting_steps)

    waiting_count =
      waiting_counts |> Map.values() |> Enum.flat_map(&Map.values/1) |> Enum.sum()

    recent_completions =
      Processing.list_processing_attempts(["succeeded"], limit: 8, order: :desc)
      |> Enum.map(&attempt_entry(&1, filters, policies))

    stage_cards =
      Enum.map(Registry.step_types(), fn step_type ->
        stage_card_data(
          step_type,
          attempt_counts,
          queued_by_type[step_type] || [],
          running_attempts,
          policies,
          socket.assigns.settings
        )
      end)

    socket
    |> assign(:stage_cards, stage_cards)
    |> assign(:article_stats, Content.article_status_counts())
    |> assign(:running_count, length(running_work))
    |> assign(:waiting_count, waiting_count)
    |> stream(:running_work, running_work, reset: true)
    |> stream(:waiting_work, waiting_work, reset: true)
    |> stream(:recent_completions, recent_completions, reset: true)
    |> then(fn socket ->
      Enum.reduce(queued_by_type, socket, fn {step_type, entries}, socket ->
        stream(socket, :"queued_#{step_type}", Enum.take(entries, 50), reset: true)
      end)
    end)
  end

  defp assign_tab_data(socket, %{tab: "batches"} = _filters) do
    entries =
      Processing.list_batches(100)
      |> Enum.map(fn batch ->
        %{
          id: batch.id,
          batch: batch,
          feed_title: batch.related["generated_feed_title"] || "Output feed",
          step_label: Registry.step_label(batch.related["step_type"] || "extraction"),
          selection_label: Format.batch_selection_label(batch.related["selection"]),
          progress: if(batch.status == "running", do: Processing.batch_progress(batch), else: nil)
        }
      end)

    socket
    |> assign(:batch_form, batch_form())
    |> assign(:feed_options, Enum.map(Publishing.list_generated_feeds(), &{&1.title, &1.id}))
    |> assign(:step_type_options, step_type_options())
    |> assign(:selection_options, selection_options())
    |> stream(:batches, entries, reset: true)
  end

  defp assign_tab_data(socket, %{tab: "attention"} = _filters) do
    groups = Attention.groups()

    {groups, actions} =
      Enum.map_reduce(groups, %{}, fn group, actions ->
        actions = if group.action, do: Map.put(actions, group.id, group.action), else: actions

        {items, actions} =
          Enum.map_reduce(group.items, actions, fn item, actions ->
            case item_action(group, item) do
              nil ->
                {Map.put(item, :action_id, nil), actions}

              action ->
                action_id = "#{group.id}:#{item.id}"
                {Map.put(item, :action_id, action_id), Map.put(actions, action_id, action)}
            end
          end)

        {%{group | items: items}, actions}
      end)

    socket
    |> assign(:attention_groups, groups)
    |> assign(:attention_actions, actions)
  end

  defp assign_tab_data(socket, %{tab: "pipeline"} = filters) do
    assign(socket, :pipeline, pipeline_entries(filters))
  end

  defp assign_tab_data(socket, %{tab: "history"} = filters) do
    policies = Content.list_site_extraction_policies() |> Map.new(&{&1.site_host, &1})
    attempts_visible? = filters.stage != "operations"

    attempts =
      if attempts_visible?,
        do:
          Processing.list_processing_attempts(
            ["running", "queued", "succeeded", "failed", "skipped"],
            filters |> attempt_opts() |> Keyword.put(:limit, 100) |> Keyword.put(:order, :desc)
          ),
        else: []

    operations = Operations.list_processing_run_entries(operation_opts(filters))

    work =
      (Enum.map(attempts, &attempt_entry(&1, filters, policies)) ++
         Enum.map(operations, &operation_entry(&1, filters)))
      |> Enum.sort_by(&entry_time/1, {:desc, DateTime})
      |> Enum.take(100)

    socket
    |> assign(:filter_form, filter_form(filters))
    |> assign(:output_options, output_options())
    |> stream(:recent_work, work, reset: true)
    |> stream(:failures, Operations.list_failures(50), reset: true)
  end

  defp item_action(%{kind: :step_failed, action: {:retry_items, feed_id, step_type, _ids}}, item),
    do: {:retry_items, feed_id, step_type, [item.id]}

  defp item_action(%{kind: :entry_failed}, item), do: {:retry_entries, [item.id]}
  defp item_action(_group, _item), do: nil

  defp stage_card_data(
         step_type,
         attempt_counts,
         queued_entries,
         running_attempts,
         policies,
         settings
       ) do
    counts = Map.get(attempt_counts, step_type, %{})
    queued = Map.get(counts, "queued", 0)
    throughput = Processing.stage_throughput(step_type)

    base = %{
      step_type: step_type,
      label: Registry.step_label(step_type),
      queued: queued,
      running: Map.get(counts, "running", 0),
      throughput: throughput,
      eta: nil,
      held: 0,
      hosts: [],
      model: nil
    }

    case step_type do
      "extraction" ->
        hosts = host_entries(queued_entries, running_attempts, policies)

        held =
          hosts |> Enum.filter(&(&1.state == "backoff")) |> Enum.map(& &1.count) |> Enum.sum()

        %{base | hosts: hosts, held: held}
        |> Map.put(
          :eta,
          Format.stage_eta_label(%{
            queued: queued,
            paused: false,
            per_minute: throughput.per_minute
          })
        )

      "digestion" ->
        %{base | model: settings.ollama_model}
        |> Map.put(
          :eta,
          Format.stage_eta_label(%{
            queued: queued,
            paused: settings.digestion_paused,
            per_minute: throughput.per_minute
          })
        )

      _other ->
        Map.put(
          base,
          :eta,
          Format.stage_eta_label(%{
            queued: queued,
            paused: false,
            per_minute: throughput.per_minute
          })
        )
    end
  end

  defp host_entries(queued_entries, running_attempts, policies) do
    now = DateTime.utc_now()

    running_hosts =
      running_attempts
      |> Enum.filter(&(&1.step_type == "extraction"))
      |> Enum.map(&attempt_host/1)
      |> MapSet.new()

    queued_hosts =
      queued_entries |> Enum.group_by(& &1.host) |> Map.new(fn {h, e} -> {h, length(e)} end)

    backoff_hosts =
      policies
      |> Map.values()
      |> Enum.filter(&Content.backoff_active?(&1, now))
      |> Enum.map(& &1.site_host)

    (Map.keys(queued_hosts) ++ backoff_hosts)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn host ->
      policy = policies[host]
      count = Map.get(queued_hosts, host, 0)
      wait_ms = if policy, do: Content.extraction_wait_ms(policy, now), else: 0

      {state, detail} =
        cond do
          MapSet.member?(running_hosts, host) ->
            {"running", "Extracting now"}

          policy && Content.backoff_active?(policy, now) ->
            {"backoff",
             "Backoff for #{human_wait(wait_ms)} · #{policy.consecutive_rate_limits} consecutive rate limits"}

          wait_ms > 0 ->
            {"pacing", "Pacing · next request in #{human_wait(wait_ms)}"}

          true ->
            {"ready", "Ready"}
        end

      %{
        host: host,
        slug: String.replace(host, ~r/[^a-z0-9]+/i, "-"),
        policy_id: policy && policy.id,
        count: count,
        state: state,
        detail: detail,
        try_now?: policy != nil and (state == "backoff" or policy.consecutive_rate_limits > 0)
      }
    end)
  end

  defp pipeline_entries(filters) do
    Processing.pipeline_overview()
    |> Enum.filter(fn entry ->
      is_nil(filters.generated_feed_id) or entry.feed.id == filters.generated_feed_id
    end)
  end

  defp attempt_opts(filters) do
    [
      step_type: stage_step_type(filters.stage),
      generated_feed_id: filters.generated_feed_id,
      article_id: filters.article_id,
      batch_run_id: filters.batch_run_id
    ]
  end

  defp operation_opts(filters) do
    [
      stage: filters.stage,
      generated_feed_id: filters.generated_feed_id,
      article_id: filters.article_id,
      batch_run_id: filters.batch_run_id,
      limit: 100
    ]
  end

  defp attempt_entry(attempt, filters, policies) do
    host = attempt_host(attempt)
    policy = policies[host]

    %{
      id: "attempt-#{attempt.id}",
      kind: :attempt,
      attempt: attempt,
      filters: filters,
      host: host,
      feed_titles: attempt_feed_titles(attempt),
      wait_label: wait_label(policy)
    }
  end

  defp operation_entry(context, filters) do
    %{
      id: "run-#{context.id}",
      kind: :operation,
      run: context.run,
      context: context,
      filters: filters
    }
  end

  defp queue_entries(attempts, step_type, filters, policies) do
    attempts
    |> Enum.filter(&(&1.step_type == step_type))
    |> case do
      attempts when step_type == "extraction" ->
        attempts
        |> Enum.group_by(&attempt_host/1)
        |> Enum.sort_by(fn {host, _attempts} -> host || "" end)
        |> Enum.flat_map(fn {_host, attempts} ->
          attempts
          |> Enum.with_index(1)
          |> Enum.map(fn {attempt, position} ->
            attempt
            |> attempt_entry(filters, policies)
            |> Map.merge(%{id: "#{step_type}-#{attempt.id}", position: position})
          end)
        end)

      attempts ->
        attempts
        |> Enum.with_index(1)
        |> Enum.map(fn {attempt, position} ->
          attempt
          |> attempt_entry(filters, policies)
          |> Map.merge(%{id: "#{step_type}-#{attempt.id}", position: position})
        end)
    end
  end

  defp delayed_site_entries(queued_extraction, running_attempts, policies) do
    running_hosts =
      running_attempts
      |> Enum.filter(&(&1.step_type == "extraction"))
      |> Enum.map(&attempt_host/1)
      |> MapSet.new()

    queued_extraction
    |> Enum.group_by(& &1.host)
    |> Enum.flat_map(fn {host, entries} ->
      policy = policies[host]
      wait_ms = if policy, do: Content.extraction_wait_ms(policy), else: 0
      running? = MapSet.member?(running_hosts, host)

      cond do
        running? ->
          [site_waiting_entry(host, entries, "Waiting behind the active extraction")]

        (wait_ms > 0 and policy) && Content.backoff_active?(policy, DateTime.utc_now()) ->
          [site_waiting_entry(host, entries, "Backoff active for #{human_wait(wait_ms)}")]

        wait_ms > 0 ->
          [site_waiting_entry(host, entries, "Website pacing delay for #{human_wait(wait_ms)}")]

        true ->
          []
      end
    end)
    |> Enum.sort_by(& &1.subject)
  end

  defp site_waiting_entry(host, entries, reason) do
    %{
      id: "site-#{host}",
      kind: :site_delay,
      stage: "extraction",
      subject: host || "Unknown website",
      reason: reason,
      count: length(entries)
    }
  end

  defp blocked_entries(item_steps) do
    item_steps
    |> Enum.group_by(fn item_step ->
      {item_step.step_type, item_step.generated_feed_item.generated_feed.id}
    end)
    |> Enum.map(fn {{step_type, feed_id}, item_steps} ->
      feed = List.first(item_steps).generated_feed_item.generated_feed

      %{
        id: "blocked-#{step_type}-#{feed_id}",
        kind: :prerequisite,
        stage: step_type,
        subject: feed.title,
        reason: waiting_reason(step_type),
        count: length(item_steps)
      }
    end)
    |> Enum.sort_by(&{&1.stage, &1.subject})
  end

  defp attempt_host(%{step_type: "extraction", article: article}) do
    Content.site_host(article.resolved_url || article.canonical_url)
  end

  defp attempt_host(_attempt), do: nil

  defp attempt_feed_titles(attempt) do
    direct_feeds =
      [
        attempt.generated_feed_item && attempt.generated_feed_item.generated_feed,
        attempt.generated_feed_item_step &&
          attempt.generated_feed_item_step.generated_feed_item.generated_feed
      ]

    affected_feeds =
      Enum.map(attempt.affected_item_steps, & &1.generated_feed_item.generated_feed)

    (direct_feeds ++ affected_feeds)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.map(& &1.title)
    |> Enum.sort()
  end

  defp feed_titles(%{feed_titles: []}), do: "No output feed context"
  defp feed_titles(%{feed_titles: titles}), do: Enum.join(titles, " · ")

  defp entry_time(%{kind: :attempt, attempt: attempt}) do
    attempt.finished_at || attempt.started_at || attempt.inserted_at
  end

  defp entry_time(%{kind: :operation, run: run}), do: run.started_at

  defp stage_options do
    [
      {"All", "all"},
      {"Extraction", "extraction"},
      {"Digestion", "digestion"},
      {"Operations", "operations"}
    ]
  end

  defp output_options do
    [{"All output feeds", ""} | Enum.map(Publishing.list_generated_feeds(), &{&1.title, &1.id})]
  end

  defp filter_form(filters) do
    to_form(%{"generated_feed_id" => filters.generated_feed_id || ""}, as: :filters)
  end

  defp start_batch(socket, nil, _step_type, _selection),
    do: {:noreply, put_flash(socket, :error, "Choose an output feed")}

  defp start_batch(socket, feed_id, step_type, selection) do
    case Processing.start_feed_batch(feed_id, "manual", step_type, selection: selection) do
      {:ok, _batch} ->
        verb = if selection == :failed, do: "retry batch", else: "batch"
        message = "#{Registry.step_label(step_type)} #{verb} started"
        {:noreply, socket |> put_flash(:info, message) |> refresh_now()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, Format.processing_error_message(reason))}
    end
  end

  defp batch_form, do: to_form(%{"selection" => "not_requested"}, as: :batch)

  defp step_type_options, do: Enum.map(Registry.step_types(), &{Registry.step_label(&1), &1})

  defp selection_options,
    do: [
      {"Items never processed by this step", "not_requested"},
      {"Items whose step failed", "failed"}
    ]

  defp attention_error(:run_already_finished), do: "That run already finished"
  defp attention_error(:no_action), do: "Nothing to do for that item"
  defp attention_error(reason), do: Format.processing_error_message(reason)

  defp processing_path(filters) do
    params =
      %{
        tab: if(filters.tab == "queue", do: nil, else: filters.tab),
        stage: if(filters.stage == "all", do: nil, else: filters.stage),
        generated_feed_id: filters.generated_feed_id,
        article_id: filters.article_id,
        batch_run_id: filters.batch_run_id
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    ~p"/processing?#{params}"
  end

  defp parse_id(id), do: Format.parse_id(id)

  defp allowed(value, allowed, fallback), do: if(value in allowed, do: value, else: fallback)
  defp stage_step_type(stage) when stage in ["extraction", "digestion"], do: stage
  defp stage_step_type(_stage), do: nil

  defp model_configured?(%{ollama_model: model}) when is_binary(model),
    do: String.trim(model) != ""

  defp model_configured?(_settings), do: false

  defp wait_label(nil), do: nil

  defp wait_label(policy) do
    case Content.extraction_wait_ms(policy) do
      wait_ms when wait_ms > 0 -> "Available in #{human_wait(wait_ms)}"
      _wait_ms -> nil
    end
  end

  defp human_wait(milliseconds) when milliseconds < 60_000,
    do: "#{max(div(milliseconds, 1_000), 1)}s"

  defp human_wait(milliseconds) when milliseconds < 3_600_000,
    do: "#{max(div(milliseconds, 60_000), 1)}m"

  defp human_wait(milliseconds), do: "#{div(milliseconds, 3_600_000)}h"

  defp waiting_reason("digestion"), do: "Waiting for article extraction"
  defp waiting_reason(_step_type), do: "Waiting for pipeline prerequisites"

  defp attempt_implementation(attempt) do
    get_in(attempt.input_snapshot, ["config", "model"]) || attempt.implementation_key
  end

  defp retry_label(%{input_snapshot: %{"request" => request}}) do
    case request do
      %{
        "retry_origin" => "automatic_rate_limit",
        "retry_number" => number,
        "retry_limit" => limit
      } ->
        "Automatic retry #{number} of #{limit}"

      %{"retry_origin" => "manual"} ->
        "Manual retry"

      %{"retry_origin" => "manual_batch"} ->
        "Manual batch retry"

      _request ->
        nil
    end
  end

  defp retry_label(_attempt), do: nil

  defp operation_label(%{
         run_type: "pipeline_batch",
         related: %{"selection" => "failed", "step_type" => step_type}
       }),
       do: "#{stage_label(step_type)} retry batch"

  defp operation_label(%{run_type: "pipeline_batch", related: %{"step_type" => step_type}}),
    do: "#{stage_label(step_type)} batch"

  defp operation_label(run), do: Format.run_type_label(run.run_type)

  defp stage_label("extraction"), do: "Extraction"
  defp stage_label("digestion"), do: "Digestion"
  defp stage_label(value), do: Format.status_label(value)

  defp stage_badge_class("extraction"), do: "badge badge-info badge-soft"
  defp stage_badge_class("digestion"), do: "badge badge-secondary badge-soft"
  defp stage_badge_class(_stage), do: "badge badge-ghost"
end
