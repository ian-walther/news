defmodule Newspaper.PipelineStepsTest do
  use Newspaper.DataCase

  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineStep, PipelineStepAttempt}
  alias Newspaper.Publishing
  alias Newspaper.Repo

  describe "create_step/2" do
    test "positions steps canonically regardless of creation order and rejects duplicates" do
      feed = feed!()
      configure_model!()

      assert {:ok, extraction} = Processing.create_step(feed, "extraction")
      assert {:ok, digestion} = Processing.create_step(feed, "digestion")
      assert extraction.position == 0
      assert digestion.position == 1
      assert {:error, :step_exists} = Processing.create_step(feed, "extraction")

      assert {:error, {:unknown_step_type, "filtering"}} =
               Processing.create_step(feed, "filtering")

      refute function_exported?(Processing, :move_step, 2)
    end

    test "refuses a step whose prerequisites are not enabled or whose requirements are unmet" do
      feed = feed!()

      assert {:error, :extraction_step_required} = Processing.create_step(feed, "digestion")
      assert {:ok, _extraction} = Processing.create_step(feed, "extraction")
      assert {:error, :ollama_model_not_configured} = Processing.create_step(feed, "digestion")
    end
  end

  describe "update_step/2" do
    test "refuses to disable a step that another enabled step or the rendering settings depend on" do
      feed = feed!()
      configure_model!()
      {:ok, extraction} = Processing.create_step(feed, "extraction")
      {:ok, digestion} = Processing.create_step(feed, "digestion")

      assert {:error, :digestion_requires_extraction} =
               Processing.update_step(extraction, %{enabled: false})

      {:ok, feed} = Publishing.update_generated_feed(feed, %{"title_source" => "digest"})

      assert {:error, :digest_rendering_requires_digestion} =
               Processing.update_step(digestion, %{enabled: false})

      {:ok, feed} =
        Publishing.update_generated_feed(feed, %{
          "title_source" => "original",
          "link_to_hosted_article" => "true"
        })

      assert {:ok, digestion} = Processing.update_step(digestion, %{enabled: false})

      assert {:error, :rendering_requires_extraction} =
               Processing.update_step(extraction, %{enabled: false})

      {:ok, _feed} =
        Publishing.update_generated_feed(feed, %{"link_to_hosted_article" => "false"})

      assert {:ok, extraction} = Processing.update_step(extraction, %{enabled: false})

      assert {:error, :extraction_step_required} =
               Processing.update_step(digestion, %{enabled: true})

      assert {:ok, _extraction} = Processing.update_step(extraction, %{enabled: true})
      assert {:ok, _digestion} = Processing.update_step(digestion, %{enabled: true})
    end
  end

  describe "delete_step/1" do
    test "refuses removal while dependents, rendering settings, or active work rely on the step" do
      feed = feed_with_article!()
      configure_model!()
      {:ok, extraction} = Processing.create_step(feed, "extraction")
      {:ok, digestion} = Processing.create_step(feed, "digestion")

      assert {:error, :digestion_requires_extraction} = Processing.delete_step(extraction)

      {:ok, digestion} = Processing.update_step(digestion, %{enabled: false})
      assert {:error, :digestion_requires_extraction} = Processing.delete_step(extraction)

      assert {:ok, _digestion} = Processing.delete_step(digestion)

      [item] = Publishing.list_items_for_feed(feed)
      assert {:ok, [_attempt]} = Processing.request_item_step(item, "extraction")
      assert {:error, :step_has_active_work} = Processing.delete_step(extraction)

      [attempt] = Repo.all(PipelineStepAttempt)
      assert {:ok, _attempt} = Processing.finish_attempt(attempt, "failed", %{retryable: false})
      assert {:ok, _extraction} = Processing.delete_step(extraction)
      assert Processing.list_steps(feed) == []

      historical = Repo.all(GeneratedFeedItemStep)
      assert length(historical) == 2
      assert Enum.all?(historical, &is_nil(&1.pipeline_step_id))
    end

    test "re-adding a removed step reuses historical item rows instead of duplicating them" do
      feed = feed_with_article!()
      {:ok, extraction} = Processing.create_step(feed, "extraction")
      assert Repo.aggregate(GeneratedFeedItemStep, :count) == 1
      assert {:ok, _extraction} = Processing.delete_step(extraction)
      assert {:ok, re_added} = Processing.create_step(feed, "extraction")

      [row] = Repo.all(GeneratedFeedItemStep)
      assert row.pipeline_step_id == re_added.id
      assert row.position == 0
      assert Repo.aggregate(PipelineStep, :count) == 1
    end
  end

  describe "pipeline_overview/0 and addable_step_types/1" do
    test "lists each feed's chain in canonical order with coverage and addable steps" do
      feed = feed_with_article!()
      configure_model!()
      assert Processing.addable_step_types([]) == ["extraction"]

      {:ok, extraction} = Processing.create_step(feed, "extraction")
      assert Processing.addable_step_types([extraction]) == ["digestion"]

      {:ok, _digestion} = Processing.create_step(feed, "digestion")
      [overview] = Processing.pipeline_overview()

      assert overview.feed.id == feed.id
      assert overview.item_count == 1
      assert overview.held == 0
      assert Enum.map(overview.steps, & &1.step_type) == ["extraction", "digestion"]
      assert Enum.map(overview.steps, & &1.label) == ["Article extraction", "Article digestion"]
      assert hd(overview.steps).counts.not_requested == 1
      assert overview.available_step_types == []
    end
  end

  defp feed! do
    {:ok, feed} = Publishing.create_generated_feed(%{"title" => "Cars"})
    feed
  end

  defp feed_with_article! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "autopian-steps",
        url: "https://www.theautopian.com/steps/",
        title: "Steps",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, feed} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [input_feed.id]})

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    Publishing.get_generated_feed!(feed.id)
  end

  defp configure_model! do
    settings = Operations.get_settings()
    {:ok, _settings} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
  end
end
