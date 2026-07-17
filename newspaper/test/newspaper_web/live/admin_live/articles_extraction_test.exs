defmodule NewspaperWeb.AdminLive.ArticlesExtractionTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content.Article
  alias Newspaper.Extraction
  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Repo

  setup do
    original_config = Application.get_env(:newspaper, :extractors)

    on_exit(fn ->
      Application.put_env(:newspaper, :extractors, original_config)
    end)

    :ok
  end

  test "manually extracts an article from the Articles page", %{conn: conn} do
    article = create_article!("https://arstechnica.com/space/example")
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article)

    {:ok, view, _html} = live(conn, ~p"/articles")

    assert has_element?(view, "#extract-article-#{article.id}")

    view
    |> element("#extract-article-#{article.id}")
    |> render_click()

    attempt = Repo.one!(PipelineStepAttempt)
    assert attempt.status == "queued"

    assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
    assert attempt.status == "succeeded"

    article = Repo.get!(Article, article.id)
    assert article.extraction_status == "succeeded"
    assert article.extracted_content =~ "Extracted article body"
    assert has_element?(view, "a[href='/articles/#{article.guid}']")

    assert {:ok, article_view, _html} = live(conn, ~p"/articles/#{article.guid}")
    assert has_element?(article_view, "#extracted-article-content")
    assert has_element?(article_view, "a[href='https://arstechnica.com/space/example']")

    _ = :sys.get_state(view.pid)
    _ = :sys.get_state(article_view.pid)
  end

  defp configure_extraction!(article) do
    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "guid" => "feed_articles_live_extraction",
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    {:ok, step} =
      Processing.create_extraction_step(output_feed)

    {:ok, step} = Processing.update_step(step, %{enabled: false})
    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    {:ok, _step} = Processing.update_step(step, %{enabled: true})
  end

  defp create_article!(url) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Seeded Feed",
        outlet_name: "Seeded Outlet",
        url: "#{url}/feed.xml"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "#{url}#rss",
        url: url,
        title: "Seeded Article",
        published_at: ~U[2026-06-18 12:00:00Z],
        body: "<p>Original feed body.</p>",
        source_name: "Seeded Outlet",
        source_url: url,
        discovered_at: ~U[2026-06-18 12:05:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    Article
    |> Repo.get_by!(representative_raw_item_id: raw_item.id)
    |> Repo.preload(:representative_raw_item)
  end

  defp worker_script!(payload) do
    path =
      Path.join(System.tmp_dir!(), "newspaper-live-worker-#{System.unique_integer([:positive])}")

    json = Jason.encode!(payload)

    File.write!(path, """
    #!/usr/bin/env bash
    cat >/dev/null
    printf '%s\\n' '#{json}'
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp success_payload do
    %{
      schema_version: 1,
      implementation: "extraction.simple_html",
      status: "ok",
      final_url: "https://arstechnica.com/space/example",
      title: "Extracted Title",
      byline: "By Example",
      content_html: "<article><p>Extracted article body.</p></article>",
      content_text: "Extracted article body.",
      quality: %{"score" => 1, "reason" => "sufficient_content"},
      debug_metadata: %{"fixture" => true}
    }
  end
end
