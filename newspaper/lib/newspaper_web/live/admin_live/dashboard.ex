defmodule NewspaperWeb.AdminLive.Dashboard do
  use NewspaperWeb, :live_view

  alias Newspaper.{Content, Operations, Pipeline, Processing}
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    socket =
      socket
      |> stream_configure(:batches, dom_id: &"dashboard-batch-#{&1.id}")
      |> stream_configure(:recent_articles, dom_id: &"recent-article-#{&1.id}")
      |> stream_configure(:failure_groups, dom_id: &"failure-group-#{&1.id}")
      |> stream_configure(:site_backoffs, dom_id: &"site-backoff-#{&1.id}")

    {:ok, assign_data(socket)}
  end

  def handle_event("fetch_all", _params, socket) do
    Pipeline.Scheduler.fetch_now()
    {:noreply, put_flash(assign_data(socket), :info, "Feed refresh started")}
  end

  def handle_event("retry_failure", %{"id" => id}, socket) do
    failure_id = String.to_integer(id)

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Pipeline.retry_failure(failure_id)
    end)

    {:noreply, socket |> put_flash(:info, "Retry started") |> assign_data()}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="activity" />

      <header class="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Newspaper
          </p>
          <h1 class="text-2xl font-semibold text-base-content">Activity</h1>
          <p class="mt-1 text-sm text-base-content/65">Article health and recent processing.</p>
        </div>
        <button id="fetch-all-now" class="btn btn-primary self-start" phx-click="fetch_all">
          <.icon name="hero-arrow-path" class="size-4" /> Fetch all now
        </button>
      </header>

      <section id="article-health" class="mb-10 border-y border-base-300">
        <div class="grid grid-cols-2 divide-x divide-y divide-base-300 sm:grid-cols-4 sm:divide-y-0">
          <div id="article-stat-total" class="px-4 py-5 first:pl-0">
            <p class="text-xs font-medium uppercase text-base-content/55">Articles</p>
            <p class="mt-1 text-2xl font-semibold tabular-nums">{@article_stats.total}</p>
            <p class="mt-1 text-xs text-base-content/55">Stored locally</p>
          </div>
          <div id="article-stat-extracted" class="px-4 py-5">
            <p class="text-xs font-medium uppercase text-base-content/55">Extracted</p>
            <p class="mt-1 text-2xl font-semibold tabular-nums text-success">
              {@article_stats.extracted}
            </p>
            <p class="mt-1 text-xs text-base-content/55">Ready to read</p>
          </div>
          <div id="article-stat-processing" class="px-4 py-5 sm:border-l">
            <p class="text-xs font-medium uppercase text-base-content/55">Processing</p>
            <p class="mt-1 text-2xl font-semibold tabular-nums">
              {@article_stats.queued + @article_stats.running}
            </p>
            <p class="mt-1 text-xs text-base-content/55">
              {@article_stats.queued} queued · {@article_stats.running} running
            </p>
          </div>
          <div id="article-stat-failed" class="px-4 py-5">
            <p class="text-xs font-medium uppercase text-base-content/55">Needs attention</p>
            <p class={[
              "mt-1 text-2xl font-semibold tabular-nums",
              @article_stats.failed > 0 && "text-error"
            ]}>
              {@article_stats.failed}
            </p>
            <p class="mt-1 text-xs text-base-content/55">
              {@article_stats.not_requested} not requested
            </p>
          </div>
        </div>
      </section>

      <section :if={@batch_count > 0} id="active-batches" class="mb-10">
        <div class="mb-3 flex items-baseline justify-between gap-4">
          <h2 class="text-base font-semibold">Extraction batches</h2>
          <.link navigate={~p"/runs"} class="text-sm font-medium text-primary hover:underline">
            All runs
          </.link>
        </div>
        <div
          id="dashboard-batches"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <article
            :for={{dom_id, batch} <- @streams.batches}
            id={dom_id}
            class="grid gap-3 py-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <p class="truncate font-medium">
                  {batch.related["generated_feed_title"] || "Output feed"}
                </p>
                <span class={status_badge_class(batch.status)}>
                  {Format.status_label(batch.status)}
                </span>
              </div>
              <p class="mt-1 text-sm text-base-content/65">{Format.run_summary(batch)}</p>
              <div :if={batch.status == "running"} class="mt-3 h-1.5 overflow-hidden bg-base-200">
                <div
                  class="h-full bg-primary transition-[width] duration-300"
                  style={"width: #{batch_progress(batch)}%"}
                />
              </div>
            </div>
            <div class="text-left text-xs text-base-content/55 sm:text-right">
              <.local_time id={"batch-time-#{batch.id}"} value={batch.started_at} />
              <p class="mt-1 tabular-nums">{Format.duration(batch)}</p>
            </div>
          </article>
        </div>
      </section>

      <div class="grid gap-10 lg:grid-cols-[minmax(0,1.25fr)_minmax(20rem,0.75fr)]">
        <section id="recent-extractions">
          <div class="mb-3 flex items-baseline justify-between gap-4">
            <h2 class="text-base font-semibold">Recently extracted</h2>
            <.link
              navigate={~p"/articles?status=succeeded"}
              class="text-sm font-medium text-primary hover:underline"
            >
              Browse articles
            </.link>
          </div>
          <div
            id="recent-articles"
            phx-update="stream"
            class="divide-y divide-base-300 border-y border-base-300"
          >
            <p id="recent-articles-empty" class="hidden py-6 text-sm text-base-content/55 only:block">
              No extracted articles yet.
            </p>
            <article
              :for={{dom_id, article} <- @streams.recent_articles}
              id={dom_id}
              class="group grid gap-2 py-4 sm:grid-cols-[minmax(0,1fr)_auto] sm:items-center"
            >
              <div class="min-w-0">
                <.link
                  navigate={~p"/articles/#{article.guid}"}
                  class="font-medium leading-snug group-hover:text-primary"
                >
                  {article.title || article.canonical_url}
                </.link>
                <p class="mt-1 truncate text-xs text-base-content/55">
                  {article.outlet_name || article.extraction.site_name ||
                    article_host(article.canonical_url)}
                </p>
              </div>
              <.local_time
                id={"article-extracted-time-#{article.id}"}
                value={article.extraction.extracted_at}
                class="text-xs text-base-content/55"
              />
            </article>
          </div>
        </section>

        <div class="space-y-10">
          <section :if={@failure_group_count > 0} id="failure-groups">
            <h2 class="mb-3 text-base font-semibold">Needs attention</h2>
            <div
              id="actionable-failures"
              phx-update="stream"
              class="divide-y divide-base-300 border-y border-base-300"
            >
              <article
                :for={{dom_id, group} <- @streams.failure_groups}
                id={dom_id}
                data-source={group.source}
                class="py-4"
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0">
                    <p class="font-medium">{Format.failure_type_label(group.failure_type)}</p>
                    <p class="mt-0.5 truncate text-sm text-base-content/65">{group.source}</p>
                  </div>
                  <span class="badge badge-error badge-soft shrink-0">
                    {occurrence_label(group.count)}
                  </span>
                </div>
                <p class="mt-3 line-clamp-2 text-sm text-base-content/70">{group.message}</p>
                <div class="mt-3 flex flex-wrap items-center gap-3">
                  <button
                    :if={group.retryable_count > 0}
                    id={"retry-failure-#{group.latest_failure_id}"}
                    class="btn btn-sm"
                    phx-click="retry_failure"
                    phx-value-id={group.latest_failure_id}
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> Retry latest
                  </button>
                  <details class="text-xs text-base-content/60">
                    <summary class="cursor-pointer font-medium hover:text-base-content">
                      Debug details
                    </summary>
                    <pre class="mt-2 max-h-48 max-w-full overflow-auto whitespace-pre-wrap break-all bg-base-200 p-3 text-[0.7rem] leading-relaxed"><%= inspect(%{related: group.related, run: group.run_related}, pretty: true) %></pre>
                  </details>
                </div>
              </article>
            </div>
          </section>

          <section :if={@backoff_count > 0} id="site-backoffs">
            <h2 class="mb-3 text-base font-semibold">Site pacing</h2>
            <div
              id="site-backoff-list"
              phx-update="stream"
              class="divide-y divide-base-300 border-y border-base-300"
            >
              <article
                :for={{dom_id, policy} <- @streams.site_backoffs}
                id={dom_id}
                class="flex items-center justify-between gap-4 py-4 text-sm"
              >
                <div class="min-w-0">
                  <p class="truncate font-medium">{policy.site_host}</p>
                  <p class="mt-0.5 text-xs text-base-content/55">
                    {policy.consecutive_rate_limits} consecutive rate limits
                  </p>
                </div>
                <div class="shrink-0 text-right text-xs text-base-content/55">
                  <p>{policy.rate_limit_delay_ms} ms delay</p>
                  <.local_time id={"backoff-time-#{policy.id}"} value={policy.backoff_until} />
                </div>
              </article>
            </div>
          </section>

          <section :if={@latest_fetch} id="latest-feed-refresh">
            <h2 class="mb-3 text-base font-semibold">Latest feed refresh</h2>
            <div class="border-y border-base-300 py-4 text-sm">
              <div class="flex items-center justify-between gap-3">
                <span class={status_badge_class(@latest_fetch.status)}>
                  {Format.status_label(@latest_fetch.status)}
                </span>
                <.local_time
                  id={"latest-fetch-time-#{@latest_fetch.id}"}
                  value={@latest_fetch.started_at}
                  class="text-xs text-base-content/55"
                />
              </div>
              <p class="mt-2 text-base-content/70">{Format.run_summary(@latest_fetch)}</p>
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_data(socket) do
    stats = Content.article_status_counts()
    batches = Processing.list_recent_batches(5)
    recent_articles = Content.list_recent_extracted_articles(8)
    failure_groups = Operations.list_actionable_failure_groups(8)
    site_backoffs = Content.list_active_site_backoffs()

    socket
    |> assign(:article_stats, stats)
    |> assign(:batch_count, length(batches))
    |> assign(:failure_group_count, length(failure_groups))
    |> assign(:backoff_count, length(site_backoffs))
    |> assign(:latest_fetch, Operations.latest_run("fetch_all"))
    |> stream(:batches, batches, reset: true)
    |> stream(:recent_articles, recent_articles, reset: true)
    |> stream(:failure_groups, failure_groups, reset: true)
    |> stream(:site_backoffs, site_backoffs, reset: true)
  end

  defp batch_progress(batch) do
    counts = batch.summary_counts
    total = max(counts["total"] || 0, 1)
    complete = (counts["succeeded"] || 0) + (counts["failed"] || 0)
    min(round(complete / total * 100), 100)
  end

  defp status_badge_class("succeeded"), do: "badge badge-success badge-soft"
  defp status_badge_class("failed"), do: "badge badge-error badge-soft"
  defp status_badge_class("running"), do: "badge badge-info badge-soft"
  defp status_badge_class(_status), do: "badge badge-ghost"

  defp article_host(nil), do: "Unknown source"

  defp article_host(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
    |> to_string()
    |> String.trim_leading("www.")
  end

  defp occurrence_label(1), do: "1 occurrence"
  defp occurrence_label(count), do: "#{count} occurrences"
end
