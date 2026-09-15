defmodule Newspaper.ProcessingImplementationAuditTest do
  use Newspaper.DataCase

  alias Newspaper.{Intake, Operations, Pipeline, Processing, Publishing}
  alias Newspaper.Processing.{BatchDispatcher, GeneratedFeedItemStep, PipelineStepAttempt}

  # These are audit reproductions, intentionally outside the normal test tree.
  # Assertions encode the reconciled plan's contracts and are expected to fail
  # until the implementation is corrected.

  test "IMP-01 completion refreshes every batch sharing an execution" do
    {a, b} = feeds!()
    batch_a = batch!(a)
    batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    assert Operations.get_run!(batch_b.id).status == "succeeded"
  end

  test "IMP-02 an automatic retry keeps its member and batch active" do
    {a, _b} = feeds!()
    batch = batch!(a)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    {:ok, attempt} =
      Processing.finish_attempt(attempt, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, retry} = Processing.schedule_automatic_retry(attempt)
    assert retry.status == "queued"
    assert Operations.get_run!(batch.id).status == "running"
  end

  test "IMP-03 claiming shared work must not resurrect a cancelled item" do
    {a, b} = feeds!()
    batch_a = batch!(a)
    _batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.cancel_feed_batch(batch_a.id)
    assert item_step!(a, "extraction").status == "cancelled"
    {:ok, _} = Processing.mark_attempt_running(attempt)
    assert item_step!(a, "extraction").status == "cancelled"
  end

  test "IMP-04 cancellation cascades below an already-running member" do
    {a, _b} = feeds!()

    {:ok, _} =
      Operations.update_settings(Operations.get_settings(), %{ollama_model: "qwen3.6:27b"})

    {:ok, _} = Processing.create_step(a, "digestion")
    batch_a = batch!(a)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.mark_attempt_running(attempt)
    {:ok, _} = Processing.cancel_feed_batch(batch_a.id)
    assert item_step!(a, "digestion").status == "cancelled"
  end

  test "IMP-05 recovery retains running execution demanded by another batch" do
    {a, b} = feeds!()
    batch_a = batch!(a)
    _batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.mark_attempt_running(attempt)
    {:ok, _} = Processing.cancel_feed_batch(batch_a.id)
    assert Processing.requeue_interrupted_attempts("extraction") == 1
    assert item_step!(b, "extraction").status == "queued"
  end

  test "IMP-06 late enrollment cannot create work after cancellation" do
    {a, _b} = feeds!()

    {:ok, batch} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => a.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      })

    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    [item] = Publishing.list_items_for_feed(a)
    _result = Processing.request_item_step(item, "extraction", batch_run_id: batch.id)
    assert Repo.aggregate(PipelineStepAttempt, :count) == 0
  end

  test "IMP-07 a shared queued step cannot be removed by its non-owning feed" do
    {a, b} = feeds!()
    _batch_a = batch!(a)
    _batch_b = batch!(b)
    [definition] = Processing.list_steps(b.id)
    assert {:error, :step_has_active_work} = Processing.delete_step(definition)
  end

  test "IMP-16 a batch history includes executions owned by another batch" do
    {a, b} = feeds!()
    batch_a = batch!(a)
    batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)

    assert Enum.any?(
             Processing.list_processing_attempts(["queued"], batch_run_id: batch_b.id),
             &(&1.id == attempt.id)
           )
  end

  test "IMP-20 migration does not enroll another feed in the originating batch" do
    {a, b} = feeds!()
    batch_a = batch!(a)
    _batch_b = batch!(b)
    a_step = item_step!(a, "extraction")

    # This is the selection used by the migration, without writing its results.
    result =
      Repo.query!(
        """
        SELECT DISTINCT ON (attempt.batch_run_id, item_step.id)
          attempt.batch_run_id, item_step.id
        FROM pipeline_step_attempts AS attempt
        JOIN generated_feed_item_steps AS item_step
          ON item_step.id = attempt.generated_feed_item_step_id
          OR item_step.latest_attempt_id = attempt.id
        WHERE attempt.batch_run_id = $1
        ORDER BY attempt.batch_run_id, item_step.id, attempt.id DESC
        """,
        [batch_a.id]
      )

    assert result.rows == [[batch_a.id, a_step.id]]
  end

  defp batch!(feed) do
    {:ok, batch} = Processing.start_feed_batch(feed.id, "audit", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    batch
  end

  defp item_step!(feed, type) do
    [item] = Publishing.list_items_for_feed(feed)
    Repo.get_by!(GeneratedFeedItemStep, generated_feed_item_id: item.id, step_type: type)
  end

  defp feeds! do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    {:ok, _} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "autopian-audit",
        url: "https://www.theautopian.com/audit-shared-article/",
        title: "A shared article about an unusual manual transmission",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    {:ok, _} = Pipeline.process_input_feed(source.id, "audit")

    feeds =
      for title <- ["Cars", "Automotive favorites"] do
        {:ok, feed} =
          Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

        {:ok, _} = Pipeline.backfill_output_feed(feed.id, "audit")
        {:ok, _} = Processing.create_step(feed, "extraction")
        feed
      end

    List.to_tuple(feeds)
  end
end
