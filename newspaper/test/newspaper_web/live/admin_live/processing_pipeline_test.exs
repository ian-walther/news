defmodule NewspaperWeb.AdminLive.ProcessingPipelineTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content.ArticleExtraction
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{BatchDispatcher, PipelineStepAttempt}
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  test "renders each feed's chain in canonical order with coverage", %{conn: conn} do
    feed = feed_with_article!()
    configure_model!()
    assert {:ok, _digestion} = add_steps!(feed)

    {:ok, view, html} = live(conn, ~p"/processing?tab=pipeline")

    assert has_element?(view, "#processing-tab-pipeline[aria-current='page']")
    assert has_element?(view, "#pipeline-feed-#{feed.id}", "Cars")
    assert has_element?(view, "#chain-link-#{feed.id}-extraction", "Article extraction")
    assert has_element?(view, "#chain-link-#{feed.id}-digestion", "Article digestion")

    assert has_element?(
             view,
             "#chain-link-#{feed.id}-extraction",
             "0 of 1 ready · 1 not requested"
           )

    assert has_element?(view, "#chain-link-#{feed.id}-digestion", "1 waiting")
    refute has_element?(view, "#add-step-#{feed.id}-extraction")
    assert has_element?(view, "#source-enrichment-empty")

    extraction_at = :binary.match(html, "chain-link-#{feed.id}-extraction") |> elem(0)
    digestion_at = :binary.match(html, "chain-link-#{feed.id}-digestion") |> elem(0)
    assert extraction_at < digestion_at
  end

  test "adds, toggles, and removes steps with domain validation", %{conn: conn} do
    {:ok, feed} = Publishing.create_generated_feed(%{"title" => "Technology Reading"})
    configure_model!()

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")

    assert has_element?(view, "#add-step-#{feed.id}-extraction")
    refute has_element?(view, "#add-step-#{feed.id}-digestion")

    view |> element("#add-step-#{feed.id}-extraction") |> render_click()

    assert has_element?(view, "#chain-link-#{feed.id}-extraction")
    assert has_element?(view, "#toggle-step-#{feed.id}-extraction[checked]")
    assert has_element?(view, "#add-step-#{feed.id}-digestion")

    view |> element("#add-step-#{feed.id}-digestion") |> render_click()

    [extraction_step, digestion_step] = Processing.list_steps(feed)
    assert {extraction_step.position, digestion_step.position} == {0, 1}
    assert has_element?(view, "#chain-link-#{feed.id}-digestion")

    html = view |> element("#toggle-step-#{feed.id}-extraction") |> render_click()
    assert html =~ "Disable article digestion before disabling extraction"
    assert Processing.get_step!(extraction_step.id).enabled

    {:ok, _feed} =
      Publishing.update_generated_feed(Publishing.get_generated_feed!(feed.id), %{
        "title_source" => "digest",
        "body_source" => "digest_summary"
      })

    html = view |> element("#toggle-step-#{feed.id}-digestion") |> render_click()
    assert html =~ "Digest title or summary requires article digestion"
    assert Processing.get_step!(digestion_step.id).enabled

    {:ok, _feed} =
      Publishing.update_generated_feed(Publishing.get_generated_feed!(feed.id), %{
        "title_source" => "original",
        "body_source" => "original_feed"
      })

    view |> element("#toggle-step-#{feed.id}-digestion") |> render_click()
    refute Processing.get_step!(digestion_step.id).enabled
    assert has_element?(view, "#chain-link-#{feed.id}-digestion[data-status='disabled']")

    view |> element("#toggle-step-#{feed.id}-extraction") |> render_click()
    refute Processing.get_step!(extraction_step.id).enabled

    view |> element("#remove-step-#{feed.id}-digestion") |> render_click()
    refute has_element?(view, "#chain-link-#{feed.id}-digestion")
    assert [_extraction_only] = Processing.list_steps(feed)

    # digestion cannot be re-added while its prerequisite is disabled
    refute has_element?(view, "#add-step-#{feed.id}-digestion")
    view |> element("#toggle-step-#{feed.id}-extraction") |> render_click()
    assert has_element?(view, "#add-step-#{feed.id}-digestion")
  end

  test "runs a step on existing items and shows live batch progress", %{conn: conn} do
    feed = feed_with_article!()
    assert {:ok, _step} = Processing.create_step(feed, "extraction")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline&generated_feed_id=#{feed.id}")

    assert has_element?(
             view,
             "#run-existing-#{feed.id}-extraction:not([disabled])",
             "Run extraction on 1 existing item"
           )

    assert has_element?(
             view,
             "#retry-failed-#{feed.id}-extraction[disabled][title='No failed items']"
           )

    view |> element("#run-existing-#{feed.id}-extraction") |> render_click()

    [batch] = Processing.list_feed_batches(feed.id)
    assert :ok = BatchDispatcher.await(batch.id)
    refresh(view)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    assert has_element?(
             view,
             "#run-existing-#{feed.id}-extraction[disabled][title='This batch is running']"
           )

    assert has_element?(view, "#chain-link-#{feed.id}-extraction", "0 of 1 · estimating")
    assert has_element?(view, "#chain-link-#{feed.id}-extraction[data-status='processing']")

    assert {:ok, _attempt} = Processing.finish_attempt(attempt, "succeeded")
    refresh(view)

    assert has_element?(view, "#chain-link-#{feed.id}-extraction", "1 of 1 ready")
    assert Repo.get!(PipelineStepAttempt, attempt.id).batch_run_id == batch.id
  end

  test "explains why digestion cannot run yet", %{conn: conn} do
    feed = feed_with_article!()
    configure_model!()
    assert {:ok, _digestion} = add_steps!(feed)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")

    assert has_element?(
             view,
             "#run-existing-#{feed.id}-digestion[disabled][title='Items are waiting for extraction']"
           )

    settings = Operations.get_settings()
    assert {:ok, _settings} = Operations.update_settings(settings, %{digestion_paused: true})
    refresh(view)

    assert has_element?(
             view,
             "#run-existing-#{feed.id}-digestion[disabled][title='Digestion is paused']"
           )
  end

  test "retries failed digestion from the chain as a durable batch", %{conn: conn} do
    feed = feed_with_article!()
    configure_model!()
    item = Repo.one!(GeneratedFeedItem) |> Repo.preload(:article)
    insert_extraction!(item.article)
    assert {:ok, _digestion} = add_steps!(feed)
    item = Repo.get!(GeneratedFeedItem, item.id)
    assert {:ok, [failed_attempt]} = Processing.request_item_step(item, "digestion")

    assert {:ok, _attempt} =
             Processing.finish_attempt(failed_attempt, "failed", %{
               failure_kind: "configuration_error",
               retryable: false,
               error_message: "No Ollama model is configured"
             })

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")

    assert has_element?(
             view,
             "#chain-link-#{feed.id}-digestion[data-status='failed']",
             "1 failed"
           )

    assert has_element?(
             view,
             "#retry-failed-#{feed.id}-digestion:not([disabled])",
             "Retry 1 failed digestion"
           )

    view |> element("#retry-failed-#{feed.id}-digestion") |> render_click()

    [retry_batch] =
      feed.id
      |> Processing.list_feed_batches()
      |> Enum.filter(&(&1.related["selection"] == "failed"))

    assert :ok = BatchDispatcher.await(retry_batch.id)
    refresh(view)

    assert has_element?(
             view,
             "#run-existing-#{feed.id}-digestion[disabled][title='A retry batch for this step is already running']"
           )

    [retry_attempt] = Processing.list_attempts_for_batch(retry_batch.id)
    assert retry_attempt.id != failed_attempt.id
    assert retry_attempt.status == "queued"
  end

  test "starts a batch from the picker on the Batches tab", %{conn: conn} do
    feed = feed_with_article!()
    assert {:ok, _step} = Processing.create_step(feed, "extraction")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")
    refute has_element?(view, "#start-batch-form")
    view |> element("#pipeline-start-batch") |> render_click()
    assert has_element?(view, "#processing-tab-batches[aria-current='page']")

    view
    |> form("#start-batch-form", %{
      "batch" => %{
        "generated_feed_id" => feed.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      }
    })
    |> render_submit()

    assert has_element?(view, "#flash-info", "Article extraction batch started")
    [batch] = Processing.list_feed_batches(feed.id)
    assert batch.related["step_type"] == "extraction"
    assert :ok = BatchDispatcher.await(batch.id)
    assert has_element?(view, "#batch-#{batch.id}[data-status='running']", "Existing items")
  end

  defp refresh(view) do
    send(view.pid, :refresh_processing_data)
    _ = :sys.get_state(view.pid)
  end

  defp add_steps!(feed) do
    {:ok, _extraction} = Processing.create_step(feed, "extraction")
    Processing.create_step(feed, "digestion")
  end

  defp configure_model! do
    settings = Operations.get_settings()
    {:ok, _settings} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
  end

  defp insert_extraction!(article) do
    %ArticleExtraction{}
    |> ArticleExtraction.changeset(%{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      final_url: article.canonical_url,
      title: article.title,
      site_name: "The Autopian",
      content_html: "<p>Clean extracted article content.</p>",
      content_text: "Clean extracted article content.",
      extracted_at: ~U[2026-07-17 12:00:00Z]
    })
    |> Repo.insert!()

    article
    |> Newspaper.Content.Article.changeset(%{extraction_status: "succeeded"})
    |> Repo.update!()
  end

  defp feed_with_article! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, _raw_item} =
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

    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_pipeline_tab_test",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    Publishing.get_generated_feed!(feed.id)
  end
end
