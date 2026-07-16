defmodule NewspaperWeb.ArticleLive.Show do
  use NewspaperWeb, :live_view

  alias Newspaper.Content
  alias Newspaper.Content.ArticleExtraction

  def mount(%{"guid" => guid}, _session, socket) do
    article = Content.get_article_by_guid!(guid)

    if is_nil(article.extraction) do
      raise Ecto.NoResultsError, queryable: ArticleExtraction
    end

    {:ok,
     socket
     |> assign(:article, article)
     |> assign(:page_title, article.title || "Article")}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <article class="mx-auto max-w-3xl">
        <header class="mb-8 border-b border-base-300 pb-6">
          <.link
            navigate={~p"/articles"}
            class="mb-5 inline-flex items-center gap-2 text-sm font-medium hover:underline"
          >
            <.icon name="hero-arrow-left" class="size-4" /> Articles
          </.link>
          <h1 class="text-3xl font-semibold leading-tight sm:text-4xl">
            {@article.extraction.title || @article.title || "Untitled"}
          </h1>
          <div class="mt-4 flex flex-wrap gap-x-4 gap-y-2 text-sm text-base-content/60">
            <span :if={@article.extraction.byline || @article.author}>
              {@article.extraction.byline || @article.author}
            </span>
            <span :if={@article.extraction.site_name || @article.outlet_name}>
              {@article.extraction.site_name || @article.outlet_name}
            </span>
            <a
              :if={@article.extraction.final_url || @article.canonical_url}
              href={@article.extraction.final_url || @article.canonical_url}
              class="font-medium text-base-content hover:underline"
            >
              Original article
            </a>
          </div>
        </header>

        <div id="extracted-article-content" class="article-content">
          {Phoenix.HTML.raw(@article.extraction.content_html)}
        </div>

        <footer class="mt-12 border-t border-base-300 py-6 text-sm text-base-content/60">
          <div>Extracted with {@article.extraction.implementation_key}</div>
          <div :if={@article.extraction.quality["reason"]}>
            Quality: {@article.extraction.quality["reason"]} ({@article.extraction.quality["score"]})
          </div>
          <div>{@article.extraction.extracted_at}</div>
        </footer>
      </article>
    </Layouts.app>
    """
  end
end
