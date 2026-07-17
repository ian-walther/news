defmodule NewspaperWeb.AdminLive.ArticlesDiscoveryTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content
  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "filters articles by status, search, source, and output feed", %{conn: conn} do
    {autopian, headlights} =
      source_article!(
        "The Autopian",
        "https://www.theautopian.com/feed/",
        "https://www.theautopian.com/round-or-rectangular-headlights/",
        "Round or rectangular headlights?",
        ~U[2026-07-15 14:00:00Z]
      )

    {_ars, spaceflight} =
      source_article!(
        "Ars Technica",
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://arstechnica.com/space/2026/07/new-spaceflight-hardware/",
        "New spaceflight hardware reaches orbit",
        ~U[2026-07-15 15:00:00Z]
      )

    cars = output_feed!("Cars", autopian, headlights, extraction?: true)
    _tech = output_feed!("Technology", nil, spaceflight)
    extract!(headlights)

    {:ok, view, _html} =
      live(
        conn,
        ~p"/articles?#{%{status: "succeeded", search: "headlights", input_feed_id: autopian.id, generated_feed_id: cars.id}}"
      )

    assert has_element?(view, "#article-#{headlights.id}", "Round or rectangular headlights?")
    refute has_element?(view, "#article-#{spaceflight.id}")
    assert has_element?(view, "#article-status-succeeded[data-active='true']")
    assert has_element?(view, "#articles-filter-form")

    {:ok, not_requested_view, _html} = live(conn, ~p"/articles?status=not_requested")
    assert has_element?(not_requested_view, "#article-status-not_requested", "Not requested")
    assert has_element?(not_requested_view, "#article-#{spaceflight.id}")
    refute has_element?(not_requested_view, "#article-#{headlights.id}")
  end

  test "paginates the durable article pool", %{conn: conn} do
    for number <- 1..26 do
      %Article{}
      |> Article.changeset(%{
        canonical_url: "https://arstechnica.com/science/briefing-#{number}",
        title: "Science briefing #{number}",
        published_at: DateTime.add(~U[2026-07-01 12:00:00Z], number, :minute),
        dedupe_scope: "feed:ars-science",
        dedupe_key: "url:https://arstechnica.com/science/briefing-#{number}"
      })
      |> Repo.insert!()
    end

    {:ok, first_page, _html} = live(conn, ~p"/articles")

    assert has_element?(first_page, "#articles-pagination", "Page 1 of 2")

    assert has_element?(
             first_page,
             "#article-#{Repo.get_by!(Article, title: "Science briefing 26").id}"
           )

    refute has_element?(
             first_page,
             "#article-#{Repo.get_by!(Article, title: "Science briefing 1").id}"
           )

    assert has_element?(first_page, "#articles-next-page")

    {:ok, second_page, _html} = live(conn, ~p"/articles?page=2")

    assert has_element?(second_page, "#articles-pagination", "Page 2 of 2")

    assert has_element?(
             second_page,
             "#article-#{Repo.get_by!(Article, title: "Science briefing 1").id}"
           )
  end

  test "shows only actions supported by the article's current state and pipeline", %{conn: conn} do
    {autopian, headlights} =
      source_article!(
        "The Autopian",
        "https://www.theautopian.com/feed/",
        "https://www.theautopian.com/round-or-rectangular-headlights/",
        "Round or rectangular headlights?",
        ~U[2026-07-15 14:00:00Z]
      )

    {_ars, spaceflight} =
      source_article!(
        "Ars Technica",
        "https://feeds.arstechnica.com/arstechnica/index",
        "https://arstechnica.com/space/2026/07/new-spaceflight-hardware/",
        "New spaceflight hardware reaches orbit",
        ~U[2026-07-15 15:00:00Z]
      )

    _cars = output_feed!("Cars", autopian, headlights, extraction?: true)
    _tech = output_feed!("Technology", nil, spaceflight)
    extract!(headlights)

    {:ok, view, _html} = live(conn, ~p"/articles")

    assert has_element?(view, "#read-article-#{headlights.id}", "Read")
    assert has_element?(view, "#extract-article-#{headlights.id}", "Re-extract")

    refute has_element?(view, "#extract-article-#{spaceflight.id}")

    assert has_element?(
             view,
             "#article-#{spaceflight.id}[data-extraction-eligible='false']",
             "No output requests extraction"
           )
  end

  defp source_article!(source_name, feed_url, article_url, title, published_at) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: source_name,
        outlet_name: source_name,
        url: feed_url
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: article_url,
        url: article_url,
        title: title,
        published_at: published_at,
        body: "<p>Original feed body for #{source_name}.</p>",
        source_name: source_name,
        source_url: URI.to_string(%URI{scheme: "https", host: URI.parse(article_url).host}),
        discovered_at: DateTime.add(published_at, 1, :minute)
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")
    article = Repo.get_by!(Article, representative_raw_item_id: raw_item.id)
    {input_feed, article}
  end

  defp output_feed!(title, input_feed, article, opts \\ []) do
    attrs = %{
      "title" => title,
      "guid" => "feed_#{title |> String.downcase() |> String.replace(" ", "_")}_discovery_test",
      "input_feed_ids" => if(input_feed, do: [input_feed.id], else: [])
    }

    {:ok, feed} = Publishing.create_generated_feed(attrs)

    if Keyword.get(opts, :extraction?, false) do
      {:ok, _step} =
        Processing.create_extraction_step(feed)
    end

    if input_feed do
      assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    else
      Publishing.create_item_if_missing(feed, Repo.preload(article, :representative_raw_item))
    end

    feed
  end

  defp extract!(article) do
    %ArticleExtraction{}
    |> ArticleExtraction.changeset(%{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      final_url: article.canonical_url,
      title: article.title,
      content_html: "<article><p>Readable article body.</p></article>",
      content_text: "Readable article body.",
      extracted_at: ~U[2026-07-16 09:30:00Z]
    })
    |> Repo.insert!()

    {:ok, _article} = Content.set_extraction_status(article, "succeeded")
  end
end
