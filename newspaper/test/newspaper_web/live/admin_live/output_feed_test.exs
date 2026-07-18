defmodule NewspaperWeb.AdminLive.OutputFeedTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction}
  alias Newspaper.Processing
  alias Newspaper.Processing.BatchDispatcher
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  test "configures processing and publishing from one workspace", %{conn: conn} do
    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology Reading",
        "guid" => "feed_pipeline_ui_test"
      })

    settings = Newspaper.Operations.get_settings()

    assert {:ok, _settings} =
             Newspaper.Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})

    Newspaper.Events.subscribe()
    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")

    assert has_element?(view, "#output-feed-settings-form")
    assert has_element?(view, "#toggle-extraction-processing:not([checked])")
    assert has_element?(view, "#toggle-digestion-processing[disabled]")
    refute has_element?(view, "select[name='pipeline_step[implementation_key]']")

    html = render_click(view, "toggle_processing", %{"step-type" => "digestion"})
    assert html =~ "Enable article extraction first"
    assert Processing.list_steps(feed) == []

    view
    |> element("#toggle-extraction-processing")
    |> render_click()

    [extraction_step] = Processing.list_steps(feed)
    assert extraction_step.implementation_key == "extraction.site_policy"
    assert extraction_step.config == %{}
    assert has_element?(view, "#processing-extraction", "Enabled")
    assert has_element?(view, "#process-existing-extraction")
    refute has_element?(view, "#toggle-digestion-processing[disabled]")

    view
    |> element("#toggle-digestion-processing")
    |> render_click()

    [extraction_step, digestion_step] = Processing.list_steps(feed)
    assert extraction_step.position == 0
    assert digestion_step.position == 1
    assert digestion_step.implementation_key == "digestion.ollama.article_digest"
    assert has_element?(view, "#processing-digestion", "Enabled")
    assert has_element?(view, "#process-existing-digestion")

    feed = Publishing.get_generated_feed!(feed.id)
    assert feed.title_source == "original"
    assert feed.body_source == "original_feed"

    view
    |> form(
      "#output-feed-settings-form",
      feed_params(feed, %{
        "link_to_hosted_article" => "true",
        "title_source" => "digest",
        "body_source" => "digest_summary"
      })
    )
    |> render_submit()

    await_rerender(view)

    feed = Publishing.get_generated_feed!(feed.id)
    assert feed.link_to_hosted_article
    assert feed.title_source == "digest"
    assert feed.body_source == "digest_summary"

    html =
      view
      |> element("#toggle-digestion-processing")
      |> render_click()

    assert html =~ "Digest title or summary requires article digestion"
    assert Processing.get_step!(digestion_step.id).enabled

    view
    |> form(
      "#output-feed-settings-form",
      feed_params(feed, %{
        "link_to_hosted_article" => "false",
        "title_source" => "original",
        "body_source" => "original_feed"
      })
    )
    |> render_submit()

    await_rerender(view)

    view
    |> element("#toggle-digestion-processing")
    |> render_click()

    refute Processing.get_step!(digestion_step.id).enabled

    view
    |> element("#toggle-extraction-processing")
    |> render_click()

    refute Processing.get_step!(extraction_step.id).enabled
    _ = :sys.get_state(view.pid)
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

  test "shows live progress for a durable existing-item extraction batch", %{conn: conn} do
    feed = output_feed_with_article!()

    {:ok, _step} =
      Processing.create_extraction_step(feed)

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")

    assert has_element?(view, "#feed-processing-summary")

    assert has_element?(
             view,
             "#process-existing-extraction:not([disabled])",
             "Extract 1 existing article"
           )

    assert has_element?(view, "#processing-extraction", "1 not requested")
    assert has_element?(view, "#view-extraction-processing[href*='/processing']")

    assert has_element?(
             view,
             "#process-existing-extraction[phx-disable-with='Queueing...']"
           )

    view
    |> element("#process-existing-extraction")
    |> render_click()

    [batch] = Processing.list_feed_batches(feed.id)
    assert :ok = BatchDispatcher.await(batch.id)
    _ = :sys.get_state(view.pid)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    assert has_element?(view, "#pipeline-batch-#{batch.id}")

    assert has_element?(
             view,
             "#view-pipeline-batch-#{batch.id}[href*='batch_run_id=#{batch.id}']"
           )

    assert has_element?(view, "#process-existing-extraction[disabled]", "Processing 0 of 1")

    assert {:ok, _attempt} = Processing.finish_attempt(attempt, "succeeded")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pipeline-batch-#{batch.id}", "1 succeeded")
    assert Repo.get!(PipelineStepAttempt, attempt.id).batch_run_id == batch.id
    _ = :sys.get_state(view.pid)
  end

  test "shows existing digestion work as waiting until extraction is available", %{conn: conn} do
    feed = output_feed_with_article!()
    assert {:ok, _step} = Processing.create_extraction_step(feed)

    settings = Newspaper.Operations.get_settings()

    assert {:ok, _settings} =
             Newspaper.Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})

    assert {:ok, _digestion_step} = Processing.create_digest_step(feed)

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}")

    assert has_element?(view, "#processing-digestion", "1 waiting")

    assert has_element?(
             view,
             "#process-existing-digestion[disabled]",
             "Waiting for extraction"
           )
  end

  defp feed_params(feed, overrides) do
    %{
      "generated_feed" => %{
        "title" => feed.title,
        "description" => feed.description || "",
        "item_limit" => Integer.to_string(feed.item_limit),
        "enabled" => to_string(feed.enabled),
        "link_to_hosted_article" => to_string(feed.link_to_hosted_article),
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

  defp await_rerender(view) do
    assert_receive {:newspaper_data_changed, :operations_changed}
    assert_receive {:newspaper_data_changed, :operations_changed}
    _ = :sys.get_state(view.pid)
  end
end
