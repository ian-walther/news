defmodule NewspaperWeb.AdminLive.Articles do
  use NewspaperWeb, :live_view

  alias Newspaper.{Content, Processing}
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_event("extract", %{"id" => article_id}, socket) do
    case Processing.enqueue_article(String.to_integer(article_id), force: true) do
      {:ok, 0} ->
        {:noreply,
         socket
         |> put_flash(:error, "No enabled output-feed extraction step applies to this article")
         |> assign_data()}

      {:ok, count} ->
        {:noreply,
         socket
         |> put_flash(:info, "Queued #{count} extraction attempts")
         |> assign_data()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, "Extraction could not be queued: #{inspect(reason)}")
         |> assign_data()}
    end
  end

  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Articles</h1>
      <.table id="articles" rows={@articles}>
        <:col :let={article} label="Title">
          <.link :if={article.extraction} navigate={~p"/articles/#{article.guid}"} class="link">
            {article.title || "Untitled"}
          </.link>
          <span :if={!article.extraction}>{article.title || "Untitled"}</span>
        </:col>
        <:col :let={article} label="URL">{article.canonical_url}</:col>
        <:col :let={article} label="Published">{article.published_at}</:col>
        <:col :let={article} label="Extraction">
          <div class="space-y-1">
            <div>{article.extraction_status}</div>
            <div
              :if={article.extraction_metadata["failure_kind"]}
              class="text-xs text-base-content/60"
            >
              {article.extraction_metadata["failure_kind"]}
            </div>
          </div>
        </:col>
        <:col :let={article} label="Appearances">{length(article.article_sources)}</:col>
        <:action :let={article}>
          <button
            id={"extract-article-#{article.id}"}
            type="button"
            phx-click="extract"
            phx-value-id={article.id}
            class="btn btn-sm"
          >
            Queue extraction
          </button>
        </:action>
      </.table>
    </main>
    """
  end

  defp assign_data(socket) do
    assign(socket, :articles, Content.list_articles())
  end
end
