defmodule NewspaperWeb.AdminLive.OutputFeedTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction}
  alias Newspaper.Processing
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  test "shows processing coverage read-only and validates rendering against the chain", %{
    conn: conn
  } do
    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology Reading",
        "guid" => "feed_pipeline_ui_test"
      })

    feed = Publishing.get_generated_feed!(feed.id)
    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")

    assert has_element?(view, "#output-feed-settings-form")
    assert has_element?(view, "#processing-coverage", "no processing steps")
    assert has_element?(view, "#manage-pipeline[href*='tab=pipeline']")
    refute has_element?(view, "#toggle-extraction-processing")
    refute has_element?(view, "#process-existing-extraction")

    html =
      view
      |> form(
        "#output-feed-settings-form",
        feed_params(feed, %{"title_source" => "digest", "body_source" => "digest_summary"})
      )
      |> render_submit()

    assert html =~ "requires article digestion"
    assert Publishing.get_generated_feed!(feed.id).title_source == "original"

    assert {:ok, _step} = Processing.create_step(feed, "extraction")
    refresh_output_feed(view)

    assert has_element?(view, "#coverage-extraction", "Article extraction")
    assert has_element?(view, "#coverage-extraction", "Enabled")
    assert has_element?(view, "#coverage-extraction", "0 of 0 ready")
    assert has_element?(view, "#backfill-output-feed", "Add matching articles")
    assert has_element?(view, "#rerender-output-feed", "Refresh RSS output")
  end

  test "rendering changes reuse stored artifacts and automatically re-render items", %{conn: conn} do
    feed = output_feed_with_article!()
    item = Repo.one!(GeneratedFeedItem) |> Repo.preload(:article)

    extraction =
      %ArticleExtraction{}
      |> ArticleExtraction.changeset(%{
        article_id: item.article.id,
        implementation_key: "extraction.simple_html",
        final_url: item.article.canonical_url,
        title: item.article.title,
        site_name: "The Autopian",
        content_html: "<p>Clean extracted article content.</p>",
        content_text: "Clean extracted article content.",
        extracted_at: ~U[2026-07-17 12:00:00Z]
      })
      |> Repo.insert!()

    item.article
    |> Article.changeset(%{extraction_status: "succeeded"})
    |> Repo.update!()

    assert {:ok, _step} = Processing.create_extraction_step(feed)
    Newspaper.Events.subscribe()

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")

    view
    |> form(
      "#output-feed-settings-form",
      feed_params(feed, %{
        "link_to_hosted_article" => "true",
        "body_source" => "extracted_content"
      })
    )
    |> render_submit()

    assert_receive {:newspaper_data_changed, :operations_changed}
    assert_receive {:newspaper_data_changed, :operations_changed}
    _ = :sys.get_state(view.pid)

    rendered_item = Repo.get!(GeneratedFeedItem, item.id)
    assert rendered_item.body_mode == "extracted_content"
    assert rendered_item.rendered_body == "<p>Clean extracted article content.</p>"
    assert rendered_item.rendered_link_url =~ "/articles/"
    assert Repo.get!(ArticleExtraction, extraction.id).content_text == extraction.content_text
    assert Repo.aggregate(ArticleDigest, :count) == 0
  end

  test "coalesces bursts of processing events before refreshing feed state", %{conn: conn} do
    feed = output_feed_with_article!()
    assert {:ok, _step} = Processing.create_extraction_step(feed)

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")
    assert has_element?(view, "#coverage-extraction", "1 not requested")

    item = Repo.one!(GeneratedFeedItem)
    assert {:ok, [_attempt]} = Processing.request_item_step(item, "extraction")

    for _index <- 1..10 do
      send(view.pid, {:newspaper_data_changed, :processing_changed})
    end

    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#coverage-extraction", "1 not requested")

    send(view.pid, :refresh_output_feed_data)
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#coverage-extraction", "1 queued")
  end

  defp refresh_output_feed(view) do
    send(view.pid, :refresh_output_feed_data)
    _ = :sys.get_state(view.pid)
  end

  defp feed_params(feed, overrides) do
    %{
      "generated_feed" => %{
        "title" => feed.title,
        "description" => feed.description || "",
        "item_limit" => Integer.to_string(feed.item_limit),
        "enabled" => to_string(feed.enabled),
        "link_to_hosted_article" => to_string(feed.link_to_hosted_article),
        "show_digest_in_hosted_article" => to_string(feed.show_digest_in_hosted_article),
        "title_source" => feed.title_source,
        "body_source" => feed.body_source,
        "input_feed_ids" => Enum.map(feed.input_feeds, & &1.id),
        "intake_group_ids" => Enum.map(feed.intake_groups, & &1.id)
      }
    }
    |> update_in(["generated_feed"], &Map.merge(&1, overrides))
  end

  defp output_feed_with_article! do
    {:ok, input_feed} =
      Newspaper.Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, _raw_item} =
      Newspaper.Intake.upsert_raw_item(input_feed, %{
        feed_guid: "autopian-headlights",
        url: "https://www.theautopian.com/round-or-rectangular-headlights/",
        title: "Round or rectangular headlights?",
        published_at: ~U[2026-07-15 14:00:00Z],
        body: "<p>Original feed body.</p>",
        source_name: "The Autopian",
        source_url: "https://www.theautopian.com/",
        discovered_at: ~U[2026-07-15 14:01:00Z]
      })

    assert {:ok, _run} = Newspaper.Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_pipeline_progress_test",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Newspaper.Pipeline.backfill_output_feed(feed.id, "test")
    Publishing.get_generated_feed!(feed.id)
  end
end
