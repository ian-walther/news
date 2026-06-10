defmodule NewspaperWeb.AdminLive.Articles do
  use NewspaperWeb, :live_view

  alias Newspaper.Content
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Articles</h1>
      <.table id="articles" rows={@articles}>
        <:col :let={article} label="Title">{article.title || "Untitled"}</:col>
        <:col :let={article} label="URL">{article.canonical_url}</:col>
        <:col :let={article} label="Published">{article.published_at}</:col>
        <:col :let={article} label="Appearances">{length(article.article_sources)}</:col>
      </.table>
    </main>
    """
  end

  defp assign_data(socket) do
    assign(socket, :articles, Content.list_articles())
  end
end
