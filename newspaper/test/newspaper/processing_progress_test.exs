defmodule Newspaper.ProcessingProgressTest do
  use Newspaper.DataCase

  alias Newspaper.Content.Article
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Repo

  @now ~U[2026-09-14 13:00:00Z]

  describe "stage_throughput/2" do
    test "reports executions completed per minute over the trailing window" do
      article = article!()

      for minutes_ago <- [5, 10, 20, 30, 40, 50] do
        completed_attempt!(article, "digestion", minutes_ago)
      end

      completed_attempt!(article, "digestion", 90)
      completed_attempt!(article, "extraction", 5)

      throughput = Processing.stage_throughput("digestion", now: @now)

      assert throughput.completed == 6
      assert throughput.window_minutes == 60
      assert_in_delta throughput.per_minute, 0.1, 0.001
    end

    test "withholds a rate until there are enough samples" do
      article = article!()
      completed_attempt!(article, "digestion", 5)
      completed_attempt!(article, "digestion", 6)

      throughput = Processing.stage_throughput("digestion", now: @now)

      assert throughput.completed == 2
      assert throughput.per_minute == nil
    end
  end

  describe "batch_progress/2" do
    test "derives done, remaining, rate, and an estimate from the batch's attempts" do
      article = article!()
      batch = batch!("digestion", %{"succeeded" => 6, "queued" => 12, "total" => 18})

      for minutes_ago <- [2, 4, 6, 8, 10, 12] do
        completed_attempt!(article, "digestion", minutes_ago, batch_run_id: batch.id)
      end

      progress = Processing.batch_progress(batch, now: @now)

      assert progress.done == 6
      assert progress.total == 18
      assert progress.remaining == 12
      assert_in_delta progress.per_minute, 0.1, 0.001
      assert progress.eta_seconds == 7200
      assert progress.eta_reason == nil
    end

    test "omits the estimate when digestion is paused" do
      article = article!()
      settings = Operations.get_settings()
      assert {:ok, _settings} = Operations.update_settings(settings, %{digestion_paused: true})
      batch = batch!("digestion", %{"succeeded" => 3, "queued" => 12, "total" => 15})

      for minutes_ago <- [2, 4, 6] do
        completed_attempt!(article, "digestion", minutes_ago, batch_run_id: batch.id)
      end

      progress = Processing.batch_progress(batch, now: @now)

      assert progress.eta_seconds == nil
      assert progress.eta_reason == :paused
    end

    test "omits the estimate before there are enough completions" do
      article = article!()
      batch = batch!("digestion", %{"succeeded" => 1, "queued" => 12, "total" => 13})
      completed_attempt!(article, "digestion", 2, batch_run_id: batch.id)

      progress = Processing.batch_progress(batch, now: @now)

      assert progress.per_minute == nil
      assert progress.eta_reason == :insufficient_samples
    end

    test "distinguishes a batch that has not enrolled from one that is complete" do
      not_started = batch!("digestion", %{})
      complete = batch!("digestion", %{"succeeded" => 4, "total" => 4})

      assert Processing.batch_progress(not_started, now: @now).eta_reason == :not_started
      assert Processing.batch_progress(complete, now: @now).eta_reason == :complete
      assert Processing.batch_progress(complete, now: @now).remaining == 0
    end
  end

  defp article! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "autopian-progress",
        url: "https://www.theautopian.com/progress/",
        title: "Progress",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")
    Repo.get_by!(Article, representative_raw_item_id: raw_item.id)
  end

  defp batch!(step_type, summary_counts) do
    {:ok, batch} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => 1,
        "generated_feed_title" => "Cars",
        "step_type" => step_type
      })

    {:ok, batch} = Operations.update_run(batch, %{summary_counts: summary_counts})
    batch
  end

  defp completed_attempt!(article, step_type, minutes_ago, opts \\ []) do
    finished_at = DateTime.add(@now, -minutes_ago * 60, :second)

    Repo.insert!(%PipelineStepAttempt{
      article_id: article.id,
      implementation_key: "test.#{step_type}",
      step_type: step_type,
      status: "succeeded",
      batch_run_id: Keyword.get(opts, :batch_run_id),
      started_at: DateTime.add(finished_at, -30, :second),
      finished_at: finished_at
    })
  end
end
