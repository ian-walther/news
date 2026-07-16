defmodule NewspaperWeb.AdminLive.DashboardTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content
  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Repo

  test "updates active batch progress when pipeline data changes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#active-batches")

    assert {:ok, batch} =
             Operations.start_run("pipeline_batch", "test", %{
               "generated_feed_id" => 42,
               "generated_feed_title" => "Cars"
             })

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#dashboard-batch-#{batch.id}", "Cars")
    assert has_element?(view, "#active-batches")
  end

  test "shows article health and recently extracted articles", %{conn: conn} do
    article = extracted_article!()

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#article-stat-total", "1")
    assert has_element?(view, "#article-stat-extracted", "1")

    assert has_element?(
             view,
             "#recent-article-#{article.id} a[href='/articles/#{article.guid}']",
             "Round or rectangular headlights?"
           )
  end

  test "groups actionable failures while preserving retry and debug details", %{conn: conn} do
    for message <- ["HTTP 429", "HTTP 429 from retry"] do
      assert {:ok, _failure} =
               Operations.create_failure(%{
                 failure_type: "pipeline_step_rate_limited",
                 message: message,
                 retryable: true,
                 related: %{
                   "url" => "https://www.theautopian.com/round-or-rectangular-headlights/"
                 }
               })
    end

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#failure-groups [data-source='theautopian.com']", "2 occurrences")
    assert has_element?(view, "#failure-groups details", "Debug details")
    assert has_element?(view, "#failure-groups button", "Retry latest")
  end

  test "does not show resolved feed failures as actionable", %{conn: conn} do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/arstechnica/index"
      })

    {:ok, _failure} =
      Operations.create_failure(%{
        failure_type: "fetch_input_feed_failed",
        message: "temporary timeout",
        retryable: true,
        related: %{
          "input_feed_id" => feed.id,
          "url" => feed.url
        }
      })

    {:ok, feed} = Intake.mark_input_feed_fetched(feed, "ok")
    assert feed.last_fetch_status == "ok"

    {:ok, view, _html} = live(conn, ~p"/")

    refute has_element?(view, "#failure-groups")
  end

  defp extracted_article! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "autopian-headlights",
        url: "https://www.theautopian.com/round-or-rectangular-headlights/",
        title: "Round or rectangular headlights?",
        published_at: ~U[2026-07-15 14:00:00Z],
        body: "<p>Original feed body.</p>",
        source_name: "The Autopian",
        source_url: "https://www.theautopian.com/",
        discovered_at: ~U[2026-07-15 14:01:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")
    article = Repo.get_by!(Article, representative_raw_item_id: raw_item.id)

    %ArticleExtraction{}
    |> ArticleExtraction.changeset(%{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      final_url: article.canonical_url,
      title: article.title,
      content_html: "<article><p>Readable article.</p></article>",
      content_text: "Readable article.",
      extracted_at: ~U[2026-07-16 09:30:00Z]
    })
    |> Repo.insert!()

    {:ok, article} = Content.set_extraction_status(article, "succeeded")
    article
  end
end
