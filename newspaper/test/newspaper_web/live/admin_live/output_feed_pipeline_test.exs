defmodule NewspaperWeb.AdminLive.OutputFeedPipelineTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "configures an output feed pipeline from the admin UI", %{conn: conn} do
    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology Reading",
        "guid" => "feed_pipeline_ui_test",
        "process_items" => true
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#new-pipeline-step-form")
    assert has_element?(view, "#process-existing-items")

    view
    |> form("#new-pipeline-step-form",
      pipeline_step: %{
        "implementation_key" => "extraction.simple_html",
        "timeout_ms" => "30000",
        "minimum_text_length" => "750"
      }
    )
    |> render_submit()

    [step] = Processing.list_steps(feed)
    assert step.config["timeout_ms"] == 30_000
    assert step.config["minimum_text_length"] == 750
    assert has_element?(view, "#steps-#{step.id}")

    view
    |> element("#edit-step-#{step.id}")
    |> render_click()

    view
    |> form("#edit-pipeline-step-form-#{step.id}",
      pipeline_step: %{
        "enabled" => "false",
        "timeout_ms" => "45000",
        "minimum_text_length" => "1000"
      }
    )
    |> render_submit()

    step = Processing.get_step!(step.id)
    refute step.enabled
    assert step.config["timeout_ms"] == 45_000

    view
    |> element("#toggle-step-#{step.id}")
    |> render_click()

    assert Processing.get_step!(step.id).enabled

    view
    |> element("#delete-step-#{step.id}")
    |> render_click()

    assert Processing.list_steps(feed) == []
    refute Repo.get(Newspaper.Processing.PipelineStep, step.id)
  end

  test "shows live progress for a durable existing-item extraction batch", %{conn: conn} do
    feed = output_feed_with_article!()

    {:ok, _step} =
      Processing.create_step(feed, %{
        "implementation_key" => "extraction.simple_html",
        "timeout_ms" => 20_000,
        "minimum_text_length" => 500
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#feed-processing-summary")

    assert has_element?(
             view,
             "#process-existing-items:not([disabled])",
             "Extract 1 unprocessed article"
           )

    view
    |> element("#process-existing-items")
    |> render_click()

    [batch] = Processing.list_feed_batches(feed.id)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    assert has_element?(view, "#pipeline-batch-#{batch.id}")
    assert has_element?(view, "#process-existing-items[disabled]", "Processing 0 of 1")

    assert {:ok, _attempt} = Processing.finish_attempt(attempt, "succeeded")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#pipeline-batch-#{batch.id}", "1 succeeded")
    assert Repo.get!(PipelineStepAttempt, attempt.id).batch_run_id == batch.id
    _ = :sys.get_state(view.pid)
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
        "process_items" => false,
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Newspaper.Pipeline.backfill_output_feed(feed.id, "test")
    feed
  end
end
