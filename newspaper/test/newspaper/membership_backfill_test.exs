defmodule Newspaper.MembershipBackfillTest do
  use Newspaper.DataCase

  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing

  alias Newspaper.Processing.{
    BatchDispatcher,
    MembershipBackfill,
    PipelineBatchAttempt,
    PipelineBatchMember
  }

  alias Newspaper.Publishing

  test "the upgrade never enrolls another feed's item in the originating batch (audit IMP-20)" do
    {feed_a, feed_b} = two_feeds!()
    {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
    :ok = BatchDispatcher.await(batch_a.id)
    {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
    :ok = BatchDispatcher.await(batch_b.id)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")

    # Simulate a pre-membership database: only attempts carry batch_run_id.
    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    :ok = MembershipBackfill.run_all(Repo)

    members = Repo.all(PipelineBatchMember)
    by_batch = Enum.group_by(members, & &1.batch_run_id, & &1.generated_feed_item_step_id)
    [step_a] = feed_item_step_ids(feed_a)
    [step_b] = feed_item_step_ids(feed_b)

    assert by_batch[batch_a.id] == [step_a]
    refute step_b in (by_batch[batch_a.id] || [])
    assert Enum.all?(members, &(&1.outcome == "succeeded"))

    lineage =
      Repo.all(PipelineBatchAttempt) |> Enum.map(&{&1.batch_run_id, &1.pipeline_step_attempt_id})

    assert {batch_a.id, attempt.id} in lineage
  end

  test "already repaired entry failures are resolved by the upgrade" do
    {:ok, source} =
      Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

    {:ok, raw_item} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "ars-1",
        url: "https://arstechnica.com/one/",
        title: "One",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    {:ok, repaired} =
      Operations.create_failure(%{
        failure_type: "raw_item_ingestion_failed",
        message: "old",
        related: %{"input_feed_id" => source.id, "feed_guid" => "ars-1"}
      })

    {:ok, open} =
      Operations.create_failure(%{
        failure_type: "raw_item_processing_failed",
        message: "still broken",
        related: %{"raw_item_id" => raw_item.id, "input_feed_id" => source.id}
      })

    :ok = MembershipBackfill.run_all(Repo)
    assert Operations.get_failure!(repaired.id).resolved_at
    refute Operations.get_failure!(open.id).resolved_at
  end

  defp feed_item_step_ids(feed) do
    for item <- Publishing.list_items_for_feed(feed),
        step <- Processing.list_item_steps(item),
        do: step.id
  end

  defp two_feeds! do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    {:ok, _} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "autopian-upgrade",
        url: "https://www.theautopian.com/upgrade/",
        title: "Shared",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    {:ok, _} = Pipeline.process_input_feed(source.id, "test")

    feeds =
      for title <- ["Cars", "Autos"] do
        {:ok, feed} =
          Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

        {:ok, _} = Pipeline.backfill_output_feed(feed.id, "test")
        feed = Publishing.get_generated_feed!(feed.id)
        {:ok, _} = Processing.create_step(feed, "extraction")
        feed
      end

    List.to_tuple(feeds)
  end
end
