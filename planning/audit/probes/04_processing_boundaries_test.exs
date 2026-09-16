defmodule Newspaper.ProcessingBoundariesAuditTest do
  use Newspaper.DataCase

  alias Newspaper.{Intake, Operations, Pipeline, Processing, Publishing}

  alias Newspaper.Processing.{
    BatchDispatcher,
    GeneratedFeedItemStep,
    MembershipBackfill,
    PipelineBatchAttempt,
    PipelineBatchMember,
    PipelineItemStepAttempt,
    PipelineStepAttempt,
    PriorityQueue
  }

  test "IMP-20 upgrade preserves open demand through an unowned legacy retry" do
    [feed] = feeds!(2)
    batch = batch!(feed)
    [attempt, _other] = Processing.list_attempts_for_batch(batch.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, retry} = Processing.schedule_automatic_retry(failed)

    # Before the redesign, retry_attempt/2 did not propagate batch_run_id.
    # The other queued member keeps this legacy batch running during retry.
    Repo.update_all(from(a in PipelineStepAttempt, where: a.id == ^retry.id),
      set: [batch_run_id: nil]
    )

    assert Operations.get_run!(batch.id).status == "running"
    migrate_membership!()

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: attempt.generated_feed_item_step_id
      )

    {:ok, _} = Processing.cancel_feed_batch(batch.id)

    assert {member.outcome, Repo.get!(PipelineStepAttempt, retry.id).status} == {nil, "skipped"}
  end

  test "IMP-20 recovery never reports a shared running batch successful with zero work" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    _ = batch!(a)
    batch_b = batch!(b)
    [item_b] = Publishing.list_items_for_feed(b)
    assert step!(item_b).status == "queued"
    migrate_membership!()

    {:ok, resumed} = Processing.resume_feed_batch(batch_b.id)
    # Missing historical evidence may require an explicit migration fallback,
    # but it cannot mean that an outstanding request completed successfully.
    refute resumed.status == "succeeded"
  end

  test "IMP-15 queued projection preserves FIFO within the bulk priority class" do
    [a, b] = feeds!(2, ["Cars", "Automotive favorites"])
    older_batch = frozen_batch!(a)
    newer_batch = frozen_batch!(b)
    [older_item, _] = Publishing.list_items_for_feed(a)
    [_, newer_item] = Publishing.list_items_for_feed(b)
    assert older_item.article_id != newer_item.article_id

    # Batch creation order and execution arrival order need not be equal.
    {:ok, [arrives_first]} =
      Processing.request_item_step(newer_item, "extraction", batch_run_id: newer_batch.id)

    {:ok, [arrives_second]} =
      Processing.request_item_step(older_item, "extraction", batch_run_id: older_batch.id)

    queue =
      PriorityQueue.new()
      |> PriorityQueue.put(arrives_first.id, :bulk)
      |> PriorityQueue.put(arrives_second.id, :bulk)

    expected = PriorityQueue.to_list(queue)
    assert expected == [arrives_first.id, arrives_second.id]

    assert Enum.map(Processing.list_queued_extraction_by_host(5), & &1.id) == expected

    assert Enum.map(Processing.list_processing_attempts(["queued"], order: :priority), & &1.id) ==
             expected
  end

  test "IMP-06 cancellation withdraws a failed member before its automatic retry is queued" do
    [feed] = feeds!(1)
    batch = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    assert Operations.get_run!(batch.id).status == "running"
    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    {:ok, retry} = Processing.schedule_automatic_retry(failed)

    item_step = Repo.get!(GeneratedFeedItemStep, attempt.generated_feed_item_step_id)

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: item_step.id
      )

    retry_state = if retry, do: {retry.status, retry.batch_run_id}, else: nil

    assert {item_step.status, member.outcome, retry_state} == {"cancelled", "cancelled", nil}
  end

  test "IMP-20 upgrade preserves retry demand before the replacement attempt exists" do
    [feed] = feeds!(2)
    batch = batch!(feed)
    [attempt, _other] = Processing.list_attempts_for_batch(batch.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    assert Operations.get_run!(batch.id).status == "running"
    migrate_membership!()

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: attempt.generated_feed_item_step_id
      )

    {:ok, retry} = Processing.schedule_automatic_retry(failed)

    assert {member.outcome, retry.batch_run_id} == {nil, batch.id}
  end

  test "IMP-20 upgrade recovery does not reset an exhausted automatic retry budget" do
    [feed] = feeds!(2)
    batch = batch!(feed)
    [attempt, other] = Processing.list_attempts_for_batch(batch.id)

    final =
      Enum.reduce(1..4, attempt, fn round, current ->
        {:ok, failed} =
          Processing.finish_attempt(current, "failed", %{
            failure_kind: "rate_limited",
            retryable: true
          })

        if round < 4 do
          {:ok, retry} = Processing.schedule_automatic_retry(failed)
          retry
        else
          failed
        end
      end)

    # The second item keeps the legacy batch active while the first has
    # exhausted its retry budget but recovery has not settled that failure.
    assert Operations.get_run!(batch.id).status == "running"
    attempt_count = Repo.aggregate(PipelineStepAttempt, :count)
    migrate_membership!()
    assert {:ok, nil} = Processing.schedule_automatic_retry(final)
    assert Repo.aggregate(PipelineStepAttempt, :count) == attempt_count

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: attempt.generated_feed_item_step_id
      )

    assert member.outcome == "failed"
    {:ok, _} = Processing.finish_attempt(other, "succeeded")
    assert Operations.get_run!(batch.id).status == "failed"
  end

  defp migrate_membership! do
    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    Repo.delete_all(PipelineItemStepAttempt)
    MembershipBackfill.run_all(Repo)
  end

  defp step!(item),
    do:
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "extraction"
      )

  defp batch!(feed) do
    {:ok, batch} = Processing.start_feed_batch(feed.id, "audit", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    batch
  end

  defp frozen_batch!(feed) do
    {:ok, batch} =
      Operations.start_run("pipeline_batch", "audit", %{
        "generated_feed_id" => feed.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      })

    for item <- Publishing.list_items_for_feed(feed),
        do:
          Repo.insert!(%PipelineBatchMember{
            batch_run_id: batch.id,
            generated_feed_item_step_id: step!(item).id
          })

    batch
  end

  defp feeds!(count, titles \\ ["Cars"]) do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for n <- 1..count do
      {:ok, _} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "boundary-#{n}",
          url: "https://www.theautopian.com/boundary-#{n}/",
          title: "A manual transmission story #{n}",
          discovered_at: DateTime.add(~U[2026-09-15 12:00:00Z], n, :second)
        })
    end

    {:ok, _} = Pipeline.process_input_feed(source.id, "audit")

    for title <- titles do
      {:ok, feed} =
        Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

      {:ok, _} = Pipeline.backfill_output_feed(feed.id, "audit")
      {:ok, _} = Processing.create_step(feed, "extraction")
      feed
    end
  end
end
