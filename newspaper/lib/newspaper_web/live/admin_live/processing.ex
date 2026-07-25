defmodule NewspaperWeb.AdminLive.Processing do
  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav

  alias Newspaper.Content
  alias Newspaper.Operations
  alias Newspaper.Processing
  alias Newspaper.Publishing
  alias NewspaperWeb.AdminLive.Format

  @stages ~w(all extraction digestion operations)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> stream_configure(:running_work, dom_id: &"running-#{&1.id}")
     |> stream_configure(:queued_extraction, dom_id: &"queued-extraction-#{&1.id}")
     |> stream_configure(:queued_digestion, dom_id: &"queued-digestion-#{&1.id}")
     |> stream_configure(:waiting_work, dom_id: &"waiting-#{&1.id}")
     |> stream_configure(:recent_work, dom_id: &"recent-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    filters = %{
      stage: allowed(params["stage"], @stages, "all"),
      generated_feed_id: parse_id(params["generated_feed_id"]),
      article_id: parse_id(params["article_id"]),
      batch_run_id: parse_id(params["batch_run_id"])
    }

    {:noreply, assign_data(socket, filters)}
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{socket.assigns.filters | generated_feed_id: parse_id(params["generated_feed_id"])}
    {:noreply, push_patch(socket, to: processing_path(filters))}
  end

  def handle_info({:newspaper_data_changed, event}, socket)
      when event in [
             :processing_changed,
             :operations_changed,
             :publishing_changed,
             :site_extraction_policies_changed
           ] do
    {:noreply, assign_data(socket, socket.assigns.filters)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="processing" />

      <header class="mb-7">
        <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Operations
        </p>
        <h1 class="text-2xl font-semibold">Processing</h1>
        <p class="mt-1 text-sm text-base-content/65">
          Live pipeline work, queue state, and execution history.
        </p>
      </header>

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

      <section
        id="processing-summary"
        class="grid border-b border-base-300 sm:grid-cols-3 sm:divide-x sm:divide-base-300"
      >
        <div class="py-5 sm:pr-6">
          <p class="text-xs font-semibold uppercase text-base-content/45">Running now</p>
          <p class="mt-1 text-2xl font-semibold tabular-nums">{@running_count}</p>
        </div>
        <div class="border-t border-base-300 py-5 sm:border-t-0 sm:px-6">
          <p class="text-xs font-semibold uppercase text-base-content/45">Queued next</p>
          <p class="mt-1 text-2xl font-semibold tabular-nums">{@queued_count}</p>
        </div>
        <div class="border-t border-base-300 py-5 sm:border-t-0 sm:pl-6">
          <p class="text-xs font-semibold uppercase text-base-content/45">Waiting</p>
          <p class="mt-1 text-2xl font-semibold tabular-nums">{@blocked_count}</p>
          <p :if={@delayed_site_count > 0} class="mt-1 text-xs text-base-content/50">
            {@delayed_site_count} delayed {if @delayed_site_count == 1, do: "site", else: "sites"}
          </p>
        </div>
      </section>

      <section class="py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Running now</h2>
          <span class="text-xs text-base-content/45">Live</span>
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

      <section :if={@filters.stage != "operations"} class="border-t border-base-300 py-8">
        <h2 class="mb-4 text-lg font-semibold">Queued next</h2>
        <div class="grid gap-8 xl:grid-cols-2 xl:divide-x xl:divide-base-300">
          <div class="min-w-0 xl:pr-8">
            <div class="mb-3 flex items-center justify-between gap-3">
              <h3 class="font-medium">Extraction by website</h3>
              <span class="text-sm tabular-nums text-base-content/55">{@extraction_queue_count}</span>
            </div>
            <div
              id="queued-extraction"
              phx-update="stream"
              class="divide-y divide-base-300 border-y border-base-300"
            >
              <div
                id="queued-extraction-empty"
                class="hidden py-6 text-sm text-base-content/55 only:block"
              >
                No extraction work is queued.
              </div>
              <.queue_row
                :for={{dom_id, entry} <- @streams.queued_extraction}
                id={dom_id}
                entry={entry}
              />
            </div>
          </div>

          <div class="min-w-0 xl:pl-8">
            <div class="mb-3 flex items-center justify-between gap-3">
              <h3 class="font-medium">Digestion</h3>
              <span class="text-sm tabular-nums text-base-content/55">{@digestion_queue_count}</span>
            </div>
            <div
              id="queued-digestion"
              phx-update="stream"
              class="divide-y divide-base-300 border-y border-base-300"
            >
              <div
                id="queued-digestion-empty"
                class="hidden py-6 text-sm text-base-content/55 only:block"
              >
                No digestion work is queued.
              </div>
              <.queue_row
                :for={{dom_id, entry} <- @streams.queued_digestion}
                id={dom_id}
                entry={entry}
              />
            </div>
          </div>
        </div>
      </section>

      <section :if={@filters.stage != "operations"} class="border-t border-base-300 py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Waiting</h2>
          <span class="text-xs text-base-content/45">Delays and prerequisites</span>
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

      <section class="border-t border-base-300 py-8">
        <div class="mb-3 flex items-baseline justify-between gap-3">
          <h2 class="text-lg font-semibold">Recent</h2>
          <span class="text-xs text-base-content/45">Newest first</span>
        </div>
        <div
          id="recent-work"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <div id="recent-work-empty" class="hidden py-7 text-sm text-base-content/55 only:block">
            No recent work matches these filters.
          </div>
          <.work_row :for={{dom_id, entry} <- @streams.recent_work} id={dom_id} entry={entry} />
        </div>
      </section>
    </Layouts.app>
    """
  end

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
          <span class={Format.status_badge_class(@entry.attempt.status)}>
            {Format.status_label(@entry.attempt.status)}
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
            patch={processing_path(%{@entry.filters | article_id: @entry.attempt.article_id})}
            class="link text-xs"
          >
            Article context
          </.link>
          <.link
            :if={@entry.attempt.batch_run_id}
            patch={processing_path(%{@entry.filters | batch_run_id: @entry.attempt.batch_run_id})}
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
          patch={processing_path(%{@entry.filters | batch_run_id: @entry.run.id})}
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

  defp assign_data(socket, filters) do
    attempt_opts = attempt_opts(filters)
    attempts_visible? = filters.stage != "operations"

    running_attempts =
      if attempts_visible?,
        do:
          Processing.list_processing_attempts(["running"], Keyword.put(attempt_opts, :limit, 250)),
        else: []

    queued_attempts =
      if attempts_visible?,
        do:
          Processing.list_processing_attempts(
            ["queued"],
            Keyword.put(attempt_opts, :limit, 5_000)
          ),
        else: []

    recent_attempts =
      if attempts_visible?,
        do:
          Processing.list_processing_attempts(
            ["succeeded", "failed", "skipped"],
            attempt_opts |> Keyword.put(:limit, 75) |> Keyword.put(:order, :desc)
          ),
        else: []

    waiting_steps =
      if attempts_visible?,
        do: Processing.list_waiting_item_steps(Keyword.put(attempt_opts, :limit, 250)),
        else: []

    attempt_counts =
      if attempts_visible?, do: Processing.processing_attempt_counts(attempt_opts), else: %{}

    waiting_counts =
      if attempts_visible?, do: Processing.waiting_item_step_counts(attempt_opts), else: %{}

    operation_entries = Operations.list_processing_run_entries(operation_opts(filters))
    running_operations = Enum.filter(operation_entries, &(&1.run.status == "running"))
    recent_operations = Enum.reject(operation_entries, &(&1.run.status == "running"))
    policies = Content.list_site_extraction_policies() |> Map.new(&{&1.site_host, &1})

    running_work =
      Enum.map(running_attempts, &attempt_entry(&1, filters, policies)) ++
        Enum.map(running_operations, &operation_entry(&1, filters))

    queued_extraction = queue_entries(queued_attempts, "extraction", filters, policies)
    queued_digestion = queue_entries(queued_attempts, "digestion", filters, policies)

    waiting_work =
      delayed_site_entries(queued_extraction, running_attempts, policies) ++
        blocked_entries(waiting_steps)

    recent_work =
      (Enum.map(recent_attempts, &attempt_entry(&1, filters, policies)) ++
         Enum.map(recent_operations, &operation_entry(&1, filters)))
      |> Enum.sort_by(&entry_time/1, {:desc, DateTime})
      |> Enum.take(75)

    blocked_count =
      waiting_counts
      |> Map.values()
      |> Enum.flat_map(&Map.values/1)
      |> Enum.sum()

    socket
    |> assign(:filters, filters)
    |> assign(:filter_form, filter_form(filters))
    |> assign(:output_options, output_options())
    |> assign(:running_count, length(running_work))
    |> assign(:queued_count, count_status(attempt_counts, "queued"))
    |> assign(:blocked_count, blocked_count)
    |> assign(:delayed_site_count, Enum.count(waiting_work, &(&1.kind == :site_delay)))
    |> assign(:extraction_queue_count, length(queued_extraction))
    |> assign(:digestion_queue_count, length(queued_digestion))
    |> stream(:running_work, running_work, reset: true)
    |> stream(:queued_extraction, Enum.take(queued_extraction, 50), reset: true)
    |> stream(:queued_digestion, Enum.take(queued_digestion, 50), reset: true)
    |> stream(:waiting_work, waiting_work, reset: true)
    |> stream(:recent_work, recent_work, reset: true)
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
      attempts when step_type == "digestion" ->
        attempts
        |> Enum.with_index(1)
        |> Enum.map(fn {attempt, position} ->
          attempt
          |> attempt_entry(filters, policies)
          |> Map.merge(%{id: "digestion-#{attempt.id}", position: position})
        end)

      attempts ->
        attempts
        |> Enum.group_by(&attempt_host/1)
        |> Enum.sort_by(fn {host, _attempts} -> host || "" end)
        |> Enum.flat_map(fn {_host, attempts} ->
          attempts
          |> Enum.with_index(1)
          |> Enum.map(fn {attempt, position} ->
            attempt
            |> attempt_entry(filters, policies)
            |> Map.merge(%{id: "extraction-#{attempt.id}", position: position})
          end)
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

  defp processing_path(filters) do
    params =
      %{
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

  defp count_status(counts, status) do
    counts
    |> Map.values()
    |> Enum.map(&Map.get(&1, status, 0))
    |> Enum.sum()
  end

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

      _request ->
        nil
    end
  end

  defp retry_label(_attempt), do: nil

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
