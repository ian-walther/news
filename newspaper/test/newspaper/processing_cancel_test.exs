defmodule Newspaper.ProcessingCancelTest do
  use Newspaper.DataCase

  alias Newspaper.Content.ArticleExtraction
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing

  alias Newspaper.Processing.{
    BatchDispatcher,
    GeneratedFeedItemStep,
    PipelineBatchMember,
    PipelineStepAttempt
  }

  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  describe "batch membership" do
    test "records requested item steps durably and derives progress from them, not from shared attempts" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)

      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)

      [member] = Repo.all(PipelineBatchMember)
      assert member.batch_run_id == batch.id
      assert member.outcome == nil

      [item_b] = Publishing.list_items_for_feed(feed_b)
      assert {:ok, [shared_attempt]} = Processing.request_item_step(item_b, "extraction")
      assert Repo.aggregate(PipelineStepAttempt, :count) == 1

      batch = Operations.get_run!(batch.id)
      assert batch.summary_counts["total"] == 1
      assert batch.summary_counts["queued"] == 1

      assert {:ok, _attempt} = Processing.finish_attempt(shared_attempt, "succeeded")

      [member] = Repo.all(PipelineBatchMember)
      assert member.outcome == "succeeded"
      batch = Operations.get_run!(batch.id)
      assert batch.status == "succeeded"
      assert batch.summary_counts["succeeded"] == 1
    end

    test "retries keep bulk ownership instead of becoming foreground work" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)

      assert {:ok, _attempt} =
               Processing.finish_attempt(attempt, "failed", %{
                 failure_kind: "rate_limited",
                 retryable: true
               })

      assert {:ok, retry} = Processing.retry_attempt(attempt.id, origin: "manual")
      assert retry.batch_run_id == batch.id
      assert Repo.aggregate(PipelineBatchMember, :count) == 1
    end
  end

  describe "cancel_feed_batch/1" do
    test "withdraws unstarted members, skips undemanded attempts, and closes the run" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(3)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      assert Repo.aggregate(PipelineStepAttempt, :count) == 3

      assert {:ok, result} = Processing.cancel_feed_batch(batch.id)
      assert result.cancelled == %{"extraction" => 3}
      assert result.running == 0
      assert length(result.attempt_ids) == 3

      assert Enum.all?(Repo.all(PipelineStepAttempt), &(&1.status == "skipped"))
      assert Enum.all?(Repo.all(PipelineStepAttempt), &(&1.failure_kind == "cancelled"))
      assert Enum.all?(feed_item_steps(feed_a), &(&1.status == "cancelled"))
      assert Enum.all?(Repo.all(PipelineBatchMember), &(&1.outcome == "cancelled"))

      batch = Operations.get_run!(batch.id)
      assert batch.status == "cancelled"
      assert batch.summary_counts["cancelled"] == 3
      assert Processing.batch_cancelled?(batch)

      assert {:ok, again} = Processing.cancel_feed_batch(batch.id)
      assert again.cancelled == %{}
      assert Processing.list_running_feed_batches() == []
    end

    test "leaves a shared attempt alone when another feed still demands it" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [item_b] = Publishing.list_items_for_feed(feed_b)
      assert {:ok, [attempt]} = Processing.request_item_step(item_b, "extraction")

      assert {:ok, result} = Processing.cancel_feed_batch(batch.id)
      assert result.attempt_ids == []
      assert Repo.get!(PipelineStepAttempt, attempt.id).status == "queued"

      [step_a] =
        GeneratedFeedItemStep
        |> join(:inner, [s], i in GeneratedFeedItem, on: i.id == s.generated_feed_item_id)
        |> where([_s, i], i.generated_feed_id == ^feed_a.id)
        |> Repo.all()

      [step_b] =
        GeneratedFeedItemStep
        |> join(:inner, [s], i in GeneratedFeedItem, on: i.id == s.generated_feed_item_id)
        |> where([_s, i], i.generated_feed_id == ^feed_b.id)
        |> Repo.all()

      assert step_a.status == "cancelled"
      assert step_b.status == "queued"
    end

    test "cascades to not-yet-started downstream steps and can be re-queued in one action" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(2)
      configure_model!()
      assert {:ok, _digestion} = Processing.create_step(feed_a, "digestion")
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)

      assert {:ok, result} = Processing.cancel_feed_batch(batch.id)
      assert result.cancelled == %{"extraction" => 2, "digestion" => 2}

      statuses =
        feed_a |> feed_item_steps() |> Enum.map(&{&1.step_type, &1.status}) |> Enum.sort()

      assert statuses == [
               {"digestion", "cancelled"},
               {"digestion", "cancelled"},
               {"extraction", "cancelled"},
               {"extraction", "cancelled"}
             ]

      assert {:ok, rerun} =
               Processing.start_feed_batch(feed_a.id, "test", "extraction", selection: :cancelled)

      assert :ok = BatchDispatcher.await(rerun.id)
      assert rerun.related["batch_type"] == "rerun_cancelled_extraction"

      statuses =
        feed_a |> feed_item_steps() |> Enum.map(&{&1.step_type, &1.status}) |> Enum.sort()

      assert statuses == [
               {"digestion", "blocked"},
               {"digestion", "blocked"},
               {"extraction", "queued"},
               {"extraction", "queued"}
             ]

      assert Repo.aggregate(
               from(m in PipelineBatchMember, where: m.batch_run_id == ^rerun.id),
               :count
             ) == 2
    end

    test "lets a running attempt finish and does not reopen the cancelled run" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(2)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [running, queued] = Processing.list_attempts_for_batch(batch.id)
      assert {:ok, running} = Processing.mark_attempt_running(running)

      assert {:ok, result} = Processing.cancel_feed_batch(batch.id)
      assert result.running == 1
      assert result.attempt_ids == [queued.id]
      assert Operations.get_run!(batch.id).status == "running"

      assert {:ok, _attempt} = Processing.finish_attempt(running, "succeeded")
      batch = Operations.get_run!(batch.id)
      assert batch.status == "cancelled"

      assert batch.summary_counts == %{
               "queued" => 0,
               "running" => 0,
               "succeeded" => 1,
               "failed" => 0,
               "skipped" => 0,
               "cancelled" => 1,
               "total" => 2
             }
    end

    test "a cancelled attempt can no longer be claimed, retried automatically, or revived by recovery" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(2)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [interrupted, queued] = Processing.list_attempts_for_batch(batch.id)
      assert {:ok, interrupted} = Processing.mark_attempt_running(interrupted)
      assert {:ok, _result} = Processing.cancel_feed_batch(batch.id)

      assert {:error, :not_queued} = Processing.mark_attempt_running(queued)

      assert 0 = Processing.requeue_interrupted_attempts("extraction")
      interrupted = Repo.get!(PipelineStepAttempt, interrupted.id)
      assert interrupted.status == "skipped"
      assert interrupted.failure_kind == "cancelled"

      assert {:ok, _attempt} =
               Processing.finish_attempt(Repo.get!(PipelineStepAttempt, queued.id), "failed", %{
                 failure_kind: "rate_limited",
                 retryable: true
               })

      assert {:ok, nil} =
               Processing.schedule_automatic_retry(Repo.get!(PipelineStepAttempt, queued.id))
    end
  end

  describe "start_feed_batch/4 eligibility and scoped selections" do
    test "refuses a second batch for the same feed and step while one is running" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)

      assert {:error, :batch_already_running} =
               Processing.start_feed_batch(feed_a.id, "test", "extraction")
    end

    test "refuses digestion batches while digestion is paused" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      configure_model!()
      assert {:ok, _digestion} = Processing.create_step(feed_a, "digestion")
      settings = Operations.get_settings()
      assert {:ok, _settings} = Operations.update_settings(settings, %{digestion_paused: true})

      assert {:error, :digestion_paused} =
               Processing.start_feed_batch(feed_a.id, "test", "digestion")
    end

    test "an explicit item selection is validated, snapshotted, and recovered from members" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(2)
      [item_one, item_two] = Publishing.list_items_for_feed(feed_a)
      [foreign_item] = Publishing.list_items_for_feed(feed_b) |> Enum.take(1)

      for item <- [item_one, item_two] do
        assert {:ok, [attempt]} = Processing.request_item_step(item, "extraction")

        assert {:ok, _attempt} =
                 Processing.finish_attempt(attempt, "failed", %{
                   failure_kind: "http_error",
                   retryable: false
                 })
      end

      failed_step_id = item_step_id(item_one, "extraction")
      foreign_step_id = item_step_id(foreign_item, "extraction")

      assert {:ok, batch} =
               Processing.start_feed_batch(feed_a.id, "test", "extraction",
                 selection: {:items, [failed_step_id, foreign_step_id, "junk"]}
               )

      assert :ok = BatchDispatcher.await(batch.id)
      assert [%{generated_feed_item_step_id: ^failed_step_id}] = Repo.all(PipelineBatchMember)
      assert batch.related["selection"] == "items"
      assert Repo.get!(GeneratedFeedItemStep, failed_step_id).status == "queued"

      assert Repo.get!(GeneratedFeedItemStep, item_step_id(item_two, "extraction")).status ==
               "failed"

      assert {:error, :no_eligible_items} =
               Processing.start_feed_batch(feed_b.id, "test", "extraction",
                 selection: {:items, [failed_step_id]}
               )
    end
  end

  defp feed_item_steps(feed) do
    GeneratedFeedItemStep
    |> join(:inner, [s], i in GeneratedFeedItem, on: i.id == s.generated_feed_item_id)
    |> where([_s, i], i.generated_feed_id == ^feed.id)
    |> Repo.all()
  end

  defp item_step_id(item, step_type) do
    Repo.get_by!(GeneratedFeedItemStep, generated_feed_item_id: item.id, step_type: step_type).id
  end

  defp configure_model! do
    settings = Operations.get_settings()
    {:ok, _settings} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
  end

  describe "shared demand across feeds (audit IMP-01..07, IMP-16)" do
    test "completing a shared execution settles every batch that requested it" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      assert {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_b.id)
      assert Repo.aggregate(PipelineStepAttempt, :count) == 1

      [attempt] = Processing.list_attempts_for_batch(batch_a.id)
      assert [^attempt] = Processing.list_attempts_for_batch(batch_b.id)
      assert {:ok, _} = Processing.finish_attempt(attempt, "succeeded")

      assert Operations.get_run!(batch_a.id).status == "succeeded"
      assert Operations.get_run!(batch_b.id).status == "succeeded"
      assert Operations.get_run!(batch_b.id).summary_counts["succeeded"] == 1
    end

    test "a permitted automatic retry keeps its member and batch active" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)

      assert {:ok, attempt} =
               Processing.finish_attempt(attempt, "failed", %{
                 failure_kind: "rate_limited",
                 retryable: true
               })

      assert Operations.get_run!(batch.id).status == "running"
      [member] = Repo.all(PipelineBatchMember)
      assert member.outcome == nil

      assert {:ok, retry} = Processing.schedule_automatic_retry(attempt)
      assert retry.status == "queued"
      assert retry.batch_run_id == batch.id
      assert Operations.get_run!(batch.id).status == "running"
      assert Operations.get_run!(batch.id).summary_counts["queued"] == 1

      assert {:ok, _} = Processing.finish_attempt(retry, "succeeded")
      assert Operations.get_run!(batch.id).status == "succeeded"
    end

    test "an exhausted retry budget settles the member as failed" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)

      final =
        Enum.reduce(1..4, attempt, fn _round, attempt ->
          assert {:ok, failed} =
                   Processing.finish_attempt(attempt, "failed", %{
                     failure_kind: "rate_limited",
                     retryable: true
                   })

          case Processing.schedule_automatic_retry(failed) do
            {:ok, %PipelineStepAttempt{} = retry} -> retry
            {:ok, nil} -> failed
          end
        end)

      assert final.status == "failed"
      assert Operations.get_run!(batch.id).status == "failed"
      assert Enum.all?(Repo.all(PipelineBatchMember), &(&1.outcome == "failed"))
    end

    test "claiming shared work does not resurrect a cancelled item step" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      assert {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_b.id)
      [attempt] = Processing.list_attempts_for_batch(batch_a.id)

      assert {:ok, _} = Processing.cancel_feed_batch(batch_a.id)
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)

      assert {:ok, running} = Processing.mark_attempt_running(attempt)
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)
      assert [%{status: "running"}] = feed_item_steps(feed_b)

      assert {:ok, _} = Processing.finish_attempt(running, "succeeded")
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)
      assert [%{status: "succeeded"}] = feed_item_steps(feed_b)
      assert Operations.get_run!(batch_a.id).status == "cancelled"
      assert Operations.get_run!(batch_b.id).status == "succeeded"
    end

    test "no-content does not convert an operator's cancellation" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      assert {:ok, _} = Processing.cancel_feed_batch(batch.id)
      [item] = Publishing.list_items_for_feed(feed_a)

      assert :ok = Processing.skip_article_steps(item.article_id, "extraction", "no content")
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)
    end

    test "cancellation cascades below a running member" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      configure_model!()
      assert {:ok, _digestion} = Processing.create_step(feed_a, "digestion")
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)
      assert {:ok, running} = Processing.mark_attempt_running(attempt)

      assert {:ok, result} = Processing.cancel_feed_batch(batch.id)
      assert result.running == 1
      assert result.cancelled == %{"digestion" => 1}

      statuses = feed_a |> feed_item_steps() |> Map.new(&{&1.step_type, &1.status})
      assert statuses == %{"extraction" => "running", "digestion" => "cancelled"}

      assert {:ok, _} = Processing.finish_attempt(running, "succeeded")
      statuses = feed_a |> feed_item_steps() |> Map.new(&{&1.step_type, &1.status})
      assert statuses == %{"extraction" => "succeeded", "digestion" => "cancelled"}
      assert Operations.get_run!(batch.id).status == "cancelled"
    end

    test "recovery keeps a running execution that another batch still demands" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      assert {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_b.id)
      [attempt] = Processing.list_attempts_for_batch(batch_a.id)
      assert {:ok, _} = Processing.mark_attempt_running(attempt)
      assert {:ok, _} = Processing.cancel_feed_batch(batch_a.id)

      assert Processing.requeue_interrupted_attempts("extraction") == 1
      assert Repo.get!(PipelineStepAttempt, attempt.id).status == "queued"
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)
      assert [%{status: "queued"}] = feed_item_steps(feed_b)
      assert Operations.get_run!(batch_a.id).status == "cancelled"
      assert Operations.get_run!(batch_b.id).status == "running"
    end

    test "recovery cancels a running execution nobody demands any more" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)
      assert {:ok, _} = Processing.mark_attempt_running(attempt)
      assert {:ok, _} = Processing.cancel_feed_batch(batch.id)

      assert Processing.requeue_interrupted_attempts("extraction") == 0
      assert Repo.get!(PipelineStepAttempt, attempt.id).status == "skipped"
      assert Operations.get_run!(batch.id).status == "cancelled"
    end

    test "an explicit retry of a cancelled batch's execution does not recreate its work" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      [item_b] = Publishing.list_items_for_feed(feed_b)
      assert {:ok, [attempt]} = Processing.request_item_step(item_b, "extraction")
      assert {:ok, _} = Processing.cancel_feed_batch(batch_a.id)

      assert {:ok, failed} =
               Processing.finish_attempt(attempt, "failed", %{
                 failure_kind: "http_error",
                 retryable: true
               })

      assert {:ok, retry} = Processing.retry_attempt(failed.id, origin: "manual")
      assert retry.batch_run_id == nil
      assert [%{status: "cancelled"}] = feed_item_steps(feed_a)
      assert [%{status: "queued"}] = feed_item_steps(feed_b)
    end

    test "late enrollment cannot create work after cancellation" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)

      {:ok, batch} =
        Operations.start_run("pipeline_batch", "test", %{
          "generated_feed_id" => feed_a.id,
          "step_type" => "extraction",
          "selection" => "not_requested"
        })

      assert {:ok, _} = Processing.cancel_feed_batch(batch.id)
      [item] = Publishing.list_items_for_feed(feed_a)

      assert {:error, :batch_cancelled} =
               Processing.request_item_step(item, "extraction", batch_run_id: batch.id)

      assert Repo.aggregate(PipelineStepAttempt, :count) == 0
    end

    test "a step definition cannot be removed while its items are served by another feed's attempt" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      assert {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_b.id)

      [definition] = Processing.list_steps(feed_b.id)
      assert {:error, :step_has_active_work} = Processing.delete_step(definition)

      assert {:ok, _} = Processing.cancel_feed_batch(batch_b.id)
      assert {:ok, _} = Processing.delete_step(Processing.get_step!(definition.id))
    end

    test "batch history lists executions the batch joined, not only those it created" do
      %{feed_a: feed_a, feed_b: feed_b} = two_feeds_sharing_articles!(1)
      assert {:ok, batch_a} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_a.id)
      assert {:ok, batch_b} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch_b.id)
      [attempt] = Processing.list_attempts_for_batch(batch_a.id)

      assert Enum.any?(
               Processing.list_processing_attempts(["queued"], batch_run_id: batch_b.id),
               &(&1.id == attempt.id)
             )

      # An automatic retry replaces the item step's pointer but never the
      # lineage: both batches keep the first attempt and gain the retry.
      assert {:ok, failed} =
               Processing.finish_attempt(attempt, "failed", %{
                 failure_kind: "rate_limited",
                 retryable: true
               })

      assert {:ok, retry} = Processing.schedule_automatic_retry(failed)
      ids = batch_b.id |> Processing.list_attempts_for_batch() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([attempt.id, retry.id])

      # A manual retry after the batches have settled is new, unattributed work.
      assert {:ok, failed_again} =
               Processing.finish_attempt(retry, "failed", %{
                 failure_kind: "http_error",
                 retryable: true
               })

      assert Operations.get_run!(batch_b.id).status == "failed"
      assert {:ok, manual} = Processing.retry_attempt(failed_again.id, origin: "manual")
      assert manual.batch_run_id == nil
      ids = batch_b.id |> Processing.list_attempts_for_batch() |> Enum.map(& &1.id)
      assert Enum.sort(ids) == Enum.sort([attempt.id, retry.id])
    end

    test "a finished batch is never reopened by later independent work" do
      %{feed_a: feed_a} = two_feeds_sharing_articles!(1)
      assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)
      [attempt] = Processing.list_attempts_for_batch(batch.id)
      assert {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
      assert Operations.get_run!(batch.id).status == "succeeded"

      [item] = Publishing.list_items_for_feed(feed_a)
      assert {:ok, [_again]} = Processing.request_item_step(item, "extraction", force: true)
      batch = Operations.get_run!(batch.id)
      assert batch.status == "succeeded"
      assert batch.summary_counts["succeeded"] == 1
    end
  end

  defp two_feeds_sharing_articles!(count) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    for index <- 1..count do
      {:ok, _raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: "autopian-cancel-#{index}",
          url: "https://www.theautopian.com/cancel-#{index}/",
          title: "Article #{index}",
          discovered_at: DateTime.add(~U[2026-09-14 12:00:00Z], index, :second)
        })
    end

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, feed_a} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [input_feed.id]})

    {:ok, feed_b} =
      Publishing.create_generated_feed(%{"title" => "Autos", "input_feed_ids" => [input_feed.id]})

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed_a.id, "test")
    assert {:ok, _run} = Pipeline.backfill_output_feed(feed_b.id, "test")
    feed_a = Publishing.get_generated_feed!(feed_a.id)
    feed_b = Publishing.get_generated_feed!(feed_b.id)
    assert {:ok, _step} = Processing.create_step(feed_a, "extraction")
    assert {:ok, _step} = Processing.create_step(feed_b, "extraction")

    %{feed_a: feed_a, feed_b: feed_b, input_feed: input_feed, extraction: ArticleExtraction}
  end
end
