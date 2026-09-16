defmodule Newspaper.ProcessingReconciliationTest do
  @moduledoc "Maintained versions of planning/audit/probes/03 (second implementation audit)."

  use Newspaper.DataCase

  alias Newspaper.{Intake, Operations, Pipeline, Processing, Publishing}

  alias Newspaper.Processing.{
    BatchDispatcher,
    GeneratedFeedItemStep,
    MembershipBackfill,
    PipelineBatchAttempt,
    PipelineBatchMember,
    PipelineStepAttempt
  }

  test "IMP-06B: a fast first completion does not finish a batch whose remaining members are unenrolled" do
    [feed] = feeds!(2)
    old = batch!(feed)
    for attempt <- Processing.list_attempts_for_batch(old.id), do: fail!(attempt)
    assert Operations.get_run!(old.id).status == "failed"

    # The durable boundary right after create_batch_with_members commits and
    # before enrollment has visited every member.
    batch = frozen_batch!(feed, "failed")
    [first, second] = Publishing.list_items_for_feed(feed)

    {:ok, [attempt]} =
      Processing.request_item_step(first, "extraction", force: true, batch_run_id: batch.id)

    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")

    batch_now = Operations.get_run!(batch.id)
    assert batch_now.status == "running"

    assert batch_now.summary_counts == %{
             "total" => 2,
             "succeeded" => 1,
             "queued" => 1,
             "running" => 0,
             "failed" => 0,
             "skipped" => 0,
             "cancelled" => 0
           }

    {:ok, _} = Processing.resume_feed_batch(batch.id)
    assert step!(second).status == "queued"
    assert Operations.get_run!(batch.id).status == "running"
    assert Enum.all?(Repo.all(PipelineBatchMember), &(&1.enrolled_at != nil))
  end

  test "IMP-06A: a request that passed the first cancellation check is refused under the demand lock" do
    [feed] = feeds!(1)
    batch = frozen_batch!(feed, "not_requested")
    [item] = Publishing.list_items_for_feed(feed)
    parent = self()
    token = make_ref()
    sup = start_supervised!({Task.Supervisor, []})

    :telemetry.attach(
      token,
      [:newspaper, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if Process.get(token) == :armed and meta.params == [batch.id] and
             String.starts_with?(meta.query, "SELECT") and
             String.contains?(meta.query, "FROM \"runs\"") do
          Process.put(token, :passed)
          send(parent, {:past_cancel_check, self(), token})

          receive do
            {:continue, ^token} -> :ok
          after
            5_000 -> raise "barrier timed out"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(token) end)

    task =
      Task.Supervisor.async(sup, fn ->
        Process.put(token, :armed)
        Processing.request_item_step(item, "extraction", batch_run_id: batch.id)
      end)

    assert_receive {:past_cancel_check, worker, ^token}, 2_000
    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    send(worker, {:continue, token})
    assert {:error, :batch_cancelled} = Task.await(task)

    assert Repo.aggregate(PipelineStepAttempt, :count) == 0
    assert step!(item).status == "cancelled"
    [member] = Repo.all(PipelineBatchMember)
    assert member.outcome == "cancelled"
    assert Operations.get_run!(batch.id).status == "cancelled"
  end

  test "IMP-06A: a finished batch refuses new demand at the write boundary" do
    [feed] = feeds!(1)
    old = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(old.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item] = Publishing.list_items_for_feed(feed)

    assert {:error, :batch_finished} =
             Processing.request_item_step(item, "extraction", force: true, batch_run_id: old.id)

    assert {:error, :batch_not_found} =
             Processing.request_item_step(item, "extraction",
               force: true,
               batch_run_id: old.id + 100_000
             )
  end

  test "IMP-02: automatic retries of independent work never join a completed batch" do
    [feed] = feeds!(1)
    old = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(old.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, [independent]} = Processing.request_item_step(item, "extraction", force: true)
    assert is_nil(independent.batch_run_id)

    {:ok, independent} =
      Processing.finish_attempt(independent, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, retry} = Processing.schedule_automatic_retry(independent)
    assert retry.batch_run_id == nil
    assert Enum.map(Processing.list_attempts_for_batch(old.id), & &1.id) == [attempt.id]
    assert Operations.get_run!(old.id).status == "succeeded"
  end

  test "IMP-16: feed-scoped history keeps a shared execution after the item step moves on" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    batch_a = batch!(a)
    _batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item_b] = Publishing.list_items_for_feed(b)
    {:ok, [_new]} = Processing.request_item_step(item_b, "extraction", force: true)

    ids =
      Processing.list_processing_attempts(["succeeded"], generated_feed_id: b.id)
      |> Enum.map(& &1.id)

    assert attempt.id in ids
  end

  test "IMP-20: the upgrade keeps a finished batch's own outcome and lineage" do
    [feed] = feeds!(1)
    old = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(old.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, [independent]} = Processing.request_item_step(item, "extraction", force: true)
    fail!(independent)
    assert Operations.get_run!(old.id).status == "succeeded"

    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    Repo.delete_all(Newspaper.Processing.PipelineItemStepAttempt)
    :ok = MembershipBackfill.run_all(Repo)

    member = Repo.get_by!(PipelineBatchMember, batch_run_id: old.id)
    assert member.outcome == "succeeded"
    assert member.enrolled_at
    assert Enum.map(Processing.list_attempts_for_batch(old.id), & &1.id) == [attempt.id]

    # Participation is rebuilt for both attempts the item step ever used.
    ids =
      Processing.list_processing_attempts(["succeeded", "failed"], generated_feed_id: feed.id)
      |> Enum.map(& &1.id)

    assert Enum.sort(ids) == Enum.sort([attempt.id, independent.id])
  end

  test "IMP-20: a running batch at upgrade claims its feed's live demand, shared or not" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    batch_a = batch!(a)
    batch_b = batch!(b)
    assert Repo.aggregate(PipelineStepAttempt, :count) == 1

    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    :ok = MembershipBackfill.run_all(Repo)

    by_batch = Repo.all(PipelineBatchMember) |> Enum.group_by(& &1.batch_run_id)
    assert length(by_batch[batch_a.id]) == 1
    # B's item step joined A's execution; it is still B's live demand.
    assert [member_b] = by_batch[batch_b.id]
    assert member_b.outcome == nil
    assert member_b.enrolled_at

    assert Enum.map(Processing.list_attempts_for_batch(batch_b.id), & &1.id) ==
             Enum.map(Processing.list_attempts_for_batch(batch_a.id), & &1.id)
  end

  test "IMP-21: a per-item re-render retry repairs exactly its item" do
    [feed] = feeds!(1)
    [item] = Publishing.list_items_for_feed(feed)

    {:ok, failure} =
      Operations.create_failure(%{
        failure_type: "generated_feed_item_render_failed",
        message: "A previous render failed",
        related: %{
          "generated_feed_id" => feed.id,
          "generated_feed_item_id" => item.id,
          "article_id" => item.article_id
        }
      })

    {:ok, gone} =
      Operations.create_failure(%{
        failure_type: "generated_feed_item_render_failed",
        message: "Item deleted since",
        related: %{"generated_feed_id" => feed.id, "generated_feed_item_id" => item.id + 100_000}
      })

    {:ok, result} = Pipeline.retry_entry_failures([failure.id, gone.id])
    assert result.results == %{failure.id => :repaired, gone.id => :target_missing}
    assert Operations.get_failure!(failure.id).resolved_at
    assert Operations.get_failure!(failure.id).retry_count == 1
  end

  test "IMP-20A: the upgrade reopens a member whose legacy unowned retry is still live" do
    [feed] = feeds!(2)
    batch = batch!(feed)
    [attempt, _other] = Processing.list_attempts_for_batch(batch.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, retry} = Processing.schedule_automatic_retry(failed)

    # Pre-redesign retries did not carry batch_run_id.
    Repo.get!(PipelineStepAttempt, retry.id)
    |> Ecto.Changeset.change(batch_run_id: nil)
    |> Repo.update!()

    assert Operations.get_run!(batch.id).status == "running"
    migrate_membership!()

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: attempt.generated_feed_item_step_id
      )

    assert member.outcome == nil
    assert retry.id in Enum.map(Processing.list_attempts_for_batch(batch.id), & &1.id)

    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    assert Repo.get!(PipelineStepAttempt, retry.id).status == "skipped"
    assert Operations.get_run!(batch.id).status == "cancelled"
  end

  test "IMP-20B: a running batch whose items joined another feed's execution keeps its demand" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    _batch_a = batch!(a)
    batch_b = batch!(b)
    [item_b] = Publishing.list_items_for_feed(b)
    assert step!(item_b).status == "queued"
    migrate_membership!()

    {:ok, resumed} = Processing.resume_feed_batch(batch_b.id)
    assert resumed.status == "running"
    assert resumed.summary_counts["queued"] == 1
  end

  test "IMP-20B: a legacy running batch with no recoverable membership is closed as failed, not succeeded" do
    [feed] = feeds!(1)

    {:ok, legacy} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => feed.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      })

    migrate_membership!()
    legacy = Operations.get_run!(legacy.id)
    assert legacy.status == "failed"
    assert legacy.error_summary =~ "could not recover"

    # The runtime guard agrees when such a batch reaches recovery anyway.
    {:ok, another} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => feed.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      })

    {:ok, resumed} = Processing.resume_feed_batch(another.id)
    assert resumed.status == "failed"
    assert resumed.error_summary =~ "could not recover"
  end

  test "IMP-15: queue projections keep arrival order within the bulk class" do
    [a, b] = feeds!(2, ["Cars", "Automotive favorites"])
    older_batch = frozen_batch!(a, "not_requested")
    newer_batch = frozen_batch!(b, "not_requested")
    [older_item, _] = Publishing.list_items_for_feed(a)
    [_, newer_item] = Publishing.list_items_for_feed(b)
    assert older_item.article_id != newer_item.article_id

    {:ok, [arrives_first]} =
      Processing.request_item_step(newer_item, "extraction", batch_run_id: newer_batch.id)

    {:ok, [arrives_second]} =
      Processing.request_item_step(older_item, "extraction", batch_run_id: older_batch.id)

    expected = [arrives_first.id, arrives_second.id]

    queue =
      Newspaper.Processing.PriorityQueue.new()
      |> Newspaper.Processing.PriorityQueue.put(arrives_first.id, :bulk)
      |> Newspaper.Processing.PriorityQueue.put(arrives_second.id, :bulk)

    assert Newspaper.Processing.PriorityQueue.to_list(queue) == expected
    assert Enum.map(Processing.list_queued_extraction_by_host(5), & &1.id) == expected

    assert Enum.map(Processing.list_processing_attempts(["queued"], order: :priority), & &1.id) ==
             expected

    assert Enum.map(Processing.list_queued_attempts("extraction"), & &1.id) == expected
  end

  test "IMP-06C: cancellation withdraws a failed member before its automatic retry is queued" do
    [feed] = feeds!(1)
    batch = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    assert Operations.get_run!(batch.id).status == "running"
    {:ok, result} = Processing.cancel_feed_batch(batch.id)
    assert result.cancelled == %{"extraction" => 1}
    assert {:ok, nil} = Processing.schedule_automatic_retry(failed)

    item_step = Repo.get!(GeneratedFeedItemStep, attempt.generated_feed_item_step_id)

    member =
      Repo.get_by!(PipelineBatchMember,
        batch_run_id: batch.id,
        generated_feed_item_step_id: item_step.id
      )

    assert {item_step.status, member.outcome} == {"cancelled", "cancelled"}
    assert Repo.aggregate(PipelineStepAttempt, :count) == 1
    assert Operations.get_run!(batch.id).status == "cancelled"
  end

  test "IMP-06C: a shared consumer keeps the retry while the cancelled batch's member is withdrawn" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    batch_a = batch!(a)
    batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)

    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, _} = Processing.cancel_feed_batch(batch_a.id)
    {:ok, retry} = Processing.schedule_automatic_retry(failed)
    assert retry.status == "queued"
    assert retry.batch_run_id == batch_b.id

    [item_a] = Publishing.list_items_for_feed(a)
    [item_b] = Publishing.list_items_for_feed(b)
    assert step!(item_a).status == "cancelled"
    assert step!(item_b).status == "queued"
    assert Operations.get_run!(batch_a.id).status == "cancelled"
    assert Operations.get_run!(batch_b.id).status == "running"
  end

  test "IMP-20C: the upgrade keeps retry-pending demand open before the replacement attempt exists" do
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

    assert member.outcome == nil

    {:ok, retry} = Processing.schedule_automatic_retry(failed)
    assert retry.batch_run_id == batch.id
    assert retry.id in Enum.map(Processing.list_attempts_for_batch(batch.id), & &1.id)

    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    assert Repo.get!(PipelineStepAttempt, retry.id).status == "skipped"
    assert Operations.get_run!(batch.id).status == "cancelled"
  end

  test "IMP-20C: a finished batch's non-retryable failure is not reopened by the upgrade" do
    [feed] = feeds!(1)
    batch = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(batch.id)
    fail!(attempt)
    assert Operations.get_run!(batch.id).status == "failed"
    migrate_membership!()

    member = Repo.get_by!(PipelineBatchMember, batch_run_id: batch.id)
    assert member.outcome == "failed"
    assert Operations.get_run!(batch.id).status == "failed"
  end

  defp migrate_membership! do
    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    Repo.delete_all(Newspaper.Processing.PipelineItemStepAttempt)
    :ok = MembershipBackfill.run_all(Repo)
  end

  defp fail!(attempt) do
    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{failure_kind: "http_error", retryable: false})

    failed
  end

  defp step!(item),
    do:
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "extraction"
      )

  defp batch!(feed) do
    {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    batch
  end

  defp frozen_batch!(feed, selection) do
    {:ok, batch} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => feed.id,
        "generated_feed_title" => feed.title,
        "step_type" => "extraction",
        "selection" => selection
      })

    for item <- Publishing.list_items_for_feed(feed) do
      Repo.insert!(%PipelineBatchMember{
        batch_run_id: batch.id,
        generated_feed_item_step_id: step!(item).id
      })
    end

    batch
  end

  defp feeds!(count, titles \\ ["Cars"]) do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for n <- 1..count do
      {:ok, _} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "reconciliation-#{n}",
          url: "https://www.theautopian.com/audit-#{n}/",
          title: "An unusual manual transmission: article #{n}",
          discovered_at: DateTime.add(~U[2026-09-14 12:00:00Z], n, :second)
        })
    end

    {:ok, _} = Pipeline.process_input_feed(source.id, "test")

    for title <- titles do
      {:ok, feed} =
        Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

      {:ok, _} = Pipeline.backfill_output_feed(feed.id, "test")
      feed = Publishing.get_generated_feed!(feed.id)
      {:ok, _} = Processing.create_step(feed, "extraction")
      feed
    end
  end
end
