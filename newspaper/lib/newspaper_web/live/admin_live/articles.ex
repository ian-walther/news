defmodule NewspaperWeb.AdminLive.Articles do
  use NewspaperWeb, :live_view

  alias Newspaper.{Content, Intake, Processing, Publishing}
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  @stages ~w(extraction digestion)
  @extraction_statuses ~w(all succeeded not_requested processing failed)
  @digestion_statuses ~w(all succeeded waiting not_requested processing failed not_enabled)

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, stream_configure(socket, :articles, dom_id: &"article-#{&1.id}")}
  end

  def handle_params(params, _uri, socket) do
    {:noreply, assign_data(socket, filters_from_params(params))}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket, socket.assigns.filters)}
  end

  def handle_event("filter", %{"filters" => params}, socket) do
    filters = %{
      socket.assigns.filters
      | search: String.trim(params["search"] || ""),
        input_feed_id: parse_optional_id(params["input_feed_id"]),
        generated_feed_id: parse_optional_id(params["generated_feed_id"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: ~p"/articles?#{filter_query(filters)}")}
  end

  def handle_event("extract", %{"id" => article_id}, socket) do
    case Processing.enqueue_article(String.to_integer(article_id), force: true) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> put_flash(:error, "No enabled output-feed extraction step applies to this article")
         |> assign_data(socket.assigns.filters)}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{count} extraction attempts")
         |> assign_data(socket.assigns.filters)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Extraction could not be queued: #{inspect(reason)}")
         |> assign_data(socket.assigns.filters)}
    end
  end

  def handle_event("digest", %{"id" => article_id}, socket) do
    case Processing.enqueue_article_step(String.to_integer(article_id), "digestion", force: true) do
      {:ok, count} when count > 0 ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued article digestion")
         |> assign_data(socket.assigns.filters)}

      {:ok, 0} ->
        {:noreply,
         socket
         |> put_flash(:info, "Article digestion requested")
         |> assign_data(socket.assigns.filters)}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Digestion could not be queued: #{inspect(reason)}")
         |> assign_data(socket.assigns.filters)}
    end
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="articles" />

      <header class="mb-8">
        <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
          Library
        </p>
        <h1 class="text-2xl font-semibold">Articles</h1>
        <p class="mt-1 text-sm text-base-content/65">
          Search the durable article pool and review processing state.
        </p>
      </header>

      <div class="mb-5 space-y-2">
        <div class="flex min-w-0 items-center gap-3">
          <p class="w-14 shrink-0 text-xs font-semibold uppercase text-base-content/45">Stage</p>
          <nav class="flex max-w-full gap-1 overflow-x-auto pb-1" aria-label="Pipeline stage">
            <.link
              :for={{value, label} <- stage_options()}
              id={"article-stage-#{value}"}
              patch={~p"/articles?#{filter_query(@filters, %{stage: value, status: "all", page: 1})}"}
              data-active={to_string(@filters.stage == value)}
              class={[
                "btn btn-sm shrink-0",
                @filters.stage == value && "btn-primary",
                @filters.stage != value && "btn-ghost"
              ]}
            >
              {label}
            </.link>
          </nav>
        </div>

        <div class="flex min-w-0 items-center gap-3">
          <p class="w-14 shrink-0 text-xs font-semibold uppercase text-base-content/45">Status</p>
          <nav class="flex max-w-full gap-1 overflow-x-auto pb-1" aria-label="Stage status">
            <.link
              :for={{value, label, count} <- status_options(@article_stats, @filters.stage)}
              id={"article-status-#{value}"}
              patch={~p"/articles?#{filter_query(@filters, %{status: value, page: 1})}"}
              data-active={to_string(@filters.status == value)}
              class={[
                "btn btn-sm shrink-0",
                @filters.status == value && "btn-primary",
                @filters.status != value && "btn-ghost"
              ]}
            >
              {label} <span class="tabular-nums opacity-60">{count}</span>
            </.link>
          </nav>
        </div>
      </div>

      <.form
        for={@filter_form}
        id="articles-filter-form"
        phx-change="filter"
        class="mb-7 grid gap-3 border-y border-base-300 py-4 md:grid-cols-[minmax(15rem,1fr)_minmax(10rem,0.55fr)_minmax(10rem,0.55fr)]"
      >
        <.input
          field={@filter_form[:search]}
          type="search"
          label="Search"
          placeholder="Title, outlet, or URL"
          phx-debounce="300"
        />
        <.input
          field={@filter_form[:input_feed_id]}
          type="select"
          label="Source"
          prompt="All sources"
          options={@input_feed_options}
        />
        <.input
          field={@filter_form[:generated_feed_id]}
          type="select"
          label="Output feed"
          prompt="All output feeds"
          options={@generated_feed_options}
        />
      </.form>

      <div class="mb-3 flex items-baseline justify-between gap-4">
        <p class="text-sm text-base-content/60">
          {@page.total_count} {if @page.total_count == 1, do: "article", else: "articles"}
        </p>
        <p class="text-xs text-base-content/50">Newest first</p>
      </div>

      <section
        id="articles"
        phx-update="stream"
        class="divide-y divide-base-300 border-y border-base-300"
      >
        <div id="articles-empty" class="hidden py-12 text-center only:block">
          <p class="font-medium">No articles match these filters.</p>
          <p class="mt-1 text-sm text-base-content/55">
            Try another stage, status, source, or search.
          </p>
        </div>

        <article
          :for={{dom_id, entry} <- @streams.articles}
          id={dom_id}
          data-extraction-eligible={to_string(entry.extraction_eligible?)}
          data-digestion-eligible={to_string(entry.digestion_eligible?)}
          class="grid gap-4 py-5 lg:grid-cols-[minmax(0,1fr)_11rem_12rem] lg:items-center"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <span class={status_badge_class(entry.article.extraction_status)}>
                {status_label(entry.article.extraction_status)}
              </span>
              <span :if={entry.article.extraction_metadata["failure_kind"]} class="text-xs text-error">
                {Format.failure_type_label(entry.article.extraction_metadata["failure_kind"])}
              </span>
            </div>
            <h2 class="mt-2 text-base font-semibold leading-snug">
              {entry.article.title || "Untitled"}
            </h2>
            <p class="mt-1 truncate text-sm text-base-content/55">
              {article_sources(entry.article)}
            </p>
            <p class="mt-1 truncate text-xs text-base-content/45">{entry.article.canonical_url}</p>
          </div>

          <div class="text-sm text-base-content/60">
            <.local_time
              id={"article-published-#{entry.article.id}"}
              value={entry.article.published_at}
            />
            <p class="mt-1 text-xs">
              {length(entry.article.article_sources)} {if length(entry.article.article_sources) == 1,
                do: "appearance",
                else: "appearances"}
            </p>
            <p class="mt-1 truncate text-xs">{article_outputs(entry.article)}</p>
            <div :if={entry.pipeline_rows != []} class="mt-2 space-y-1.5">
              <div :for={row <- entry.pipeline_rows} class="text-xs">
                <span class="text-base-content/45">{row.feed_title}</span>
                <.link
                  :for={step <- row.steps}
                  id={"article-processing-#{entry.article.id}-#{row.feed_id}-#{step.step_type}"}
                  navigate={
                    ~p"/processing?#{%{article_id: entry.article.id, generated_feed_id: row.feed_id, stage: step.step_type}}"
                  }
                  class={pipeline_badge_class(step.status)}
                >
                  {pipeline_step_label(step)}
                </.link>
              </div>
            </div>
          </div>

          <div class="flex flex-wrap items-center gap-2 lg:justify-end">
            <.link
              :if={entry.article.extraction}
              id={"read-article-#{entry.article.id}"}
              navigate={~p"/articles/#{entry.article.guid}"}
              class="btn btn-primary btn-sm"
            >
              <.icon name="hero-book-open" class="size-4" /> Read
            </.link>
            <a
              :if={entry.article.canonical_url}
              href={entry.article.canonical_url}
              target="_blank"
              rel="noreferrer"
              class="btn btn-ghost btn-sm btn-square"
              title="Open original article"
              aria-label="Open original article"
            >
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </a>
            <button
              :if={extract_action?(entry)}
              id={"extract-article-#{entry.article.id}"}
              type="button"
              phx-click="extract"
              phx-value-id={entry.article.id}
              class="btn btn-sm"
            >
              <.icon name="hero-bolt" class="size-4" /> {extract_action_label(entry.article)}
            </button>
            <button
              :if={digest_action?(entry)}
              id={"digest-article-#{entry.article.id}"}
              type="button"
              phx-click="digest"
              phx-value-id={entry.article.id}
              phx-disable-with="Queueing..."
              class="btn btn-sm"
            >
              <.icon name="hero-document-text" class="size-4" /> {digest_action_label(entry.article)}
            </button>
            <p
              :if={!entry.extraction_eligible?}
              class="basis-full text-xs text-base-content/45 lg:text-right"
            >
              No output requests extraction
            </p>
            <p
              :if={entry.extraction_eligible? && processing?(entry.article)}
              class="basis-full text-xs text-base-content/55 lg:text-right"
            >
              Extraction {entry.article.extraction_status}
            </p>
            <p
              :if={entry.digestion_eligible? && digest_processing?(entry)}
              class="basis-full text-xs text-base-content/55 lg:text-right"
            >
              Digestion processing
            </p>
          </div>
        </article>
      </section>

      <nav
        :if={@page.total_pages > 1}
        id="articles-pagination"
        class="mt-6 flex items-center justify-between gap-4"
        aria-label="Article pages"
      >
        <.link
          :if={@page.page > 1}
          id="articles-previous-page"
          patch={~p"/articles?#{filter_query(@filters, %{page: @page.page - 1})}"}
          class="btn btn-sm"
        >
          <.icon name="hero-arrow-left" class="size-4" /> Previous
        </.link>
        <span :if={@page.page == 1} />
        <p class="text-sm text-base-content/60">Page {@page.page} of {@page.total_pages}</p>
        <.link
          :if={@page.page < @page.total_pages}
          id="articles-next-page"
          patch={~p"/articles?#{filter_query(@filters, %{page: @page.page + 1})}"}
          class="btn btn-sm"
        >
          Next <.icon name="hero-arrow-right" class="size-4" />
        </.link>
        <span :if={@page.page == @page.total_pages} />
      </nav>
    </Layouts.app>
    """
  end

  defp assign_data(socket, filters) do
    page = Content.list_articles_page(Map.put(filters, :per_page, 25))
    article_ids = Enum.map(page.articles, & &1.id)
    extraction_eligible_ids = Processing.step_eligible_article_ids(article_ids, "extraction")
    digestion_eligible_ids = Processing.step_eligible_article_ids(article_ids, "digestion")

    entries =
      Enum.map(page.articles, fn article ->
        pipeline_rows = pipeline_rows(article, filters.generated_feed_id)

        %{
          id: article.id,
          article: article,
          extraction_eligible?: MapSet.member?(extraction_eligible_ids, article.id),
          digestion_eligible?: MapSet.member?(digestion_eligible_ids, article.id),
          pipeline_rows: pipeline_rows
        }
      end)

    socket
    |> assign(:filters, Map.put(filters, :page, page.page))
    |> assign(:page, page)
    |> assign(:article_stats, Content.article_filter_counts(filters))
    |> assign(:input_feed_options, Enum.map(Intake.list_input_feeds(), &{&1.name, &1.id}))
    |> assign(
      :generated_feed_options,
      Enum.map(Publishing.list_generated_feeds(), &{&1.title, &1.id})
    )
    |> assign(
      :filter_form,
      to_form(
        %{
          "search" => filters.search,
          "input_feed_id" => filters.input_feed_id,
          "generated_feed_id" => filters.generated_feed_id
        },
        as: :filters
      )
    )
    |> stream(:articles, entries, reset: true)
  end

  defp filters_from_params(params) do
    stage = allowed_stage(params["stage"])

    %{
      stage: stage,
      status: allowed_status(stage, params["status"]),
      search: String.trim(params["search"] || ""),
      input_feed_id: parse_optional_id(params["input_feed_id"]),
      generated_feed_id: parse_optional_id(params["generated_feed_id"]),
      page: parse_page(params["page"])
    }
  end

  defp filter_query(filters, overrides \\ %{}) do
    filters
    |> Map.merge(overrides)
    |> Map.take([:stage, :status, :search, :input_feed_id, :generated_feed_id, :page])
    |> Enum.reject(fn
      {:stage, "extraction"} -> true
      {:status, "all"} -> true
      {:search, ""} -> true
      {_key, nil} -> true
      {:page, 1} -> true
      _entry -> false
    end)
    |> Map.new()
  end

  defp allowed_stage(stage) when stage in @stages, do: stage
  defp allowed_stage(_stage), do: "extraction"

  defp allowed_status(_stage, "unprocessed"), do: "not_requested"
  defp allowed_status(_stage, "ready"), do: "succeeded"

  defp allowed_status("digestion", status) when status in @digestion_statuses, do: status
  defp allowed_status("extraction", status) when status in @extraction_statuses, do: status
  defp allowed_status(_stage, _status), do: "all"

  defp parse_optional_id(value) when is_integer(value) and value > 0, do: value

  defp parse_optional_id(value) when is_binary(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_optional_id(_value), do: nil

  defp parse_page(value), do: parse_optional_id(value) || 1

  defp stage_options, do: [{"extraction", "Extraction"}, {"digestion", "Digestion"}]

  defp status_options(stats, "digestion") do
    [
      {"all", "All", stats.all},
      {"succeeded", "Ready", stats.succeeded},
      {"waiting", "Waiting", stats.waiting},
      {"not_requested", "Not requested", stats.not_requested},
      {"processing", "Processing", stats.processing},
      {"failed", "Failed", stats.failed},
      {"not_enabled", "Not enabled", stats.not_enabled}
    ]
  end

  defp status_options(stats, _stage) do
    [
      {"all", "All", stats.all},
      {"succeeded", "Ready", stats.succeeded},
      {"not_requested", "Not requested", stats.not_requested},
      {"processing", "Processing", stats.processing},
      {"failed", "Failed", stats.failed}
    ]
  end

  defp status_label("succeeded"), do: "Ready"
  defp status_label("not_requested"), do: "Not requested"
  defp status_label(value), do: Format.status_label(value)

  defp status_badge_class("succeeded"), do: "badge badge-success badge-soft"
  defp status_badge_class("failed"), do: "badge badge-error badge-soft"

  defp status_badge_class(status) when status in ["queued", "running"],
    do: "badge badge-info badge-soft"

  defp status_badge_class(_status), do: "badge badge-ghost"

  defp extract_action?(entry) do
    entry.extraction_eligible? && not processing?(entry.article)
  end

  defp digest_action?(entry) do
    entry.digestion_eligible? && not is_nil(entry.article.extraction) &&
      not digest_processing?(entry)
  end

  defp digest_processing?(entry) do
    Enum.any?(entry.pipeline_rows, fn row ->
      Enum.any?(row.steps, &(&1.step_type == "digestion" and &1.status in ["queued", "running"]))
    end)
  end

  defp processing?(article), do: article.extraction_status in ["queued", "running"]

  defp extract_action_label(%{extraction: extraction}) when not is_nil(extraction),
    do: "Re-extract"

  defp extract_action_label(%{extraction_status: "failed"}), do: "Retry extraction"
  defp extract_action_label(_article), do: "Extract"

  defp digest_action_label(%{digests: [_digest | _rest]}), do: "Regenerate digest"
  defp digest_action_label(_article), do: "Digest"

  defp pipeline_rows(article, selected_feed_id) do
    article.generated_feed_items
    |> Enum.filter(&(is_nil(selected_feed_id) or &1.generated_feed_id == selected_feed_id))
    |> Enum.map(fn item ->
      snapshots = Map.new(item.pipeline_item_steps, &{&1.step_type, &1})

      current_steps =
        item.generated_feed.pipeline_steps
        |> Enum.filter(& &1.enabled)
        |> Map.new(&{&1.step_type, &1})

      step_types =
        ["extraction", "digestion"]
        |> Enum.filter(&(Map.has_key?(snapshots, &1) or Map.has_key?(current_steps, &1)))

      steps =
        Enum.map(step_types, fn step_type ->
          case Map.get(snapshots, step_type) do
            nil ->
              %{step_type: step_type, status: "not_requested", current?: true}

            item_step ->
              %{
                step_type: step_type,
                status: item_step.status,
                current?: Map.has_key?(current_steps, step_type)
              }
          end
        end)

      %{feed_id: item.generated_feed.id, feed_title: item.generated_feed.title, steps: steps}
    end)
    |> Enum.reject(&(&1.steps == []))
  end

  defp pipeline_step_label(step) do
    label = if step.step_type == "extraction", do: "Extract", else: "Digest"
    suffix = if step.current?, do: pipeline_status_label(step.status), else: "historical"
    "#{label}: #{suffix}"
  end

  defp pipeline_status_label("succeeded"), do: "ready"
  defp pipeline_status_label("not_requested"), do: "not requested"
  defp pipeline_status_label("blocked"), do: "waiting"
  defp pipeline_status_label("pending"), do: "waiting"
  defp pipeline_status_label(status), do: status

  defp pipeline_badge_class("succeeded"), do: "badge badge-success badge-soft ml-1"
  defp pipeline_badge_class("failed"), do: "badge badge-error badge-soft ml-1"

  defp pipeline_badge_class(status) when status in ["queued", "running"],
    do: "badge badge-info badge-soft ml-1"

  defp pipeline_badge_class(_status), do: "badge badge-ghost ml-1"

  defp article_sources(article) do
    article.article_sources
    |> Enum.map(& &1.input_feed.name)
    |> Enum.uniq()
    |> Enum.join(" · ")
    |> empty_fallback(article.outlet_name || article_host(article.canonical_url))
  end

  defp article_outputs(article) do
    article.generated_feed_items
    |> Enum.map(& &1.generated_feed.title)
    |> Enum.uniq()
    |> Enum.join(" · ")
    |> empty_fallback("No output feed")
  end

  defp empty_fallback("", fallback), do: fallback
  defp empty_fallback(value, _fallback), do: value

  defp article_host(nil), do: "Unknown source"

  defp article_host(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
    |> to_string()
    |> String.trim_leading("www.")
  end
end
