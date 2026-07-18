defmodule NewspaperWeb.AdminLive.OutputFeedPipelineTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "defines ordered extraction and digestion steps for an output feed", %{conn: conn} do
    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology Reading",
        "guid" => "feed_pipeline_ui_test"
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#enable-extraction-step")
    assert has_element?(view, "#enable-digestion-step[disabled]")
    refute has_element?(view, "select[name='pipeline_step[implementation_key]']")

    view
    |> element("#enable-extraction-step")
    |> render_click()

    [extraction_step] = Processing.list_steps(feed)
    assert extraction_step.implementation_key == "extraction.site_policy"
    assert extraction_step.config == %{}
    assert has_element?(view, "#steps-#{extraction_step.id}")
    assert has_element?(view, "#process-existing-extraction")

    assert :error =
             Processing.create_step(feed, %{
               "implementation_key" => "extraction.simple_html"
             })

    settings = Newspaper.Operations.get_settings()

    assert {:ok, _settings} =
             Newspaper.Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})

    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#enable-digestion-step[disabled]")

    view
    |> element("#enable-digestion-step")
    |> render_click()

    [extraction_step, digestion_step] = Processing.list_steps(feed)
    assert extraction_step.position == 0
    assert digestion_step.position == 1
    assert digestion_step.implementation_key == "digestion.ollama.article_digest"
    assert has_element?(view, "#process-existing-digestion")

    view
    |> element("#toggle-step-#{digestion_step.id}")
    |> render_click()

    refute Processing.get_step!(digestion_step.id).enabled

    view
    |> element("#delete-step-#{digestion_step.id}")
    |> render_click()

    assert [remaining_step] = Processing.list_steps(feed)
    assert remaining_step.id == extraction_step.id
    refute Repo.get(Newspaper.Processing.PipelineStep, digestion_step.id)
  end

  test "shows live progress for a durable existing-item extraction batch", %{conn: conn} do
    feed = output_feed_with_article!()

    {:ok, _step} =
      Processing.create_extraction_step(feed)

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#feed-processing-summary")

    assert has_element?(
             view,
             "#process-existing-extraction:not([disabled])",
             "Extract 1 existing article"
           )

    [step] = Processing.list_steps(feed)
    assert has_element?(view, "#steps-#{step.id}", "1 not requested")

    assert has_element?(
             view,
             "#process-existing-extraction[phx-disable-with='Queueing...']"
           )

    view
    |> element("#process-existing-extraction")
    |> render_click()

    [batch] = Processing.list_feed_batches(feed.id)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    assert has_element?(view, "#pipeline-batch-#{batch.id}")
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

    assert {:ok, digestion_step} = Processing.create_digest_step(feed)

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#steps-#{digestion_step.id}", "1 waiting")

    assert has_element?(
             view,
             "#process-existing-digestion[disabled]",
             "Waiting for extraction"
           )
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
    feed
  end
end
