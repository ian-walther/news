defmodule Newspaper.AttentionTest do
  use Newspaper.DataCase

  alias Newspaper.Content
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Operations.Attention
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{BatchDispatcher, PipelineStepAttempt}
  alias Newspaper.Publishing

  describe "step failures" do
    test "groups failed item steps by step, kind, and feed with a retry action that starts a batch" do
      %{feed: feed} = feed_with_articles!(2)
      assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
      assert :ok = BatchDispatcher.await(batch.id)

      for attempt <- Processing.list_attempts_for_batch(batch.id) do
        assert {:ok, _} =
                 Processing.finish_attempt(attempt, "failed", %{
                   failure_kind: "http_error",
                   retryable: false,
                   error_message: "HTTP 500"
                 })
      end

      assert [group] = Attention.groups()
      assert group.kind == :step_failed
      assert group.stage == "extraction"
      assert group.title == "Article request failed"
      assert group.subject == "Cars"
      assert group.count == 2
      assert group.action_label == "Retry 2"
      assert {:retry_items, feed_id, "extraction", [_, _]} = group.action
      assert feed_id == feed.id
      assert Attention.count() == 1

      assert {:ok, message} = Attention.perform(group.action)
      assert message =~ "retry batch started"
      [retry] = Processing.list_running_feed_batches()
      assert :ok = BatchDispatcher.await(retry.id)
      assert Repo.aggregate(PipelineStepAttempt, :count) == 4
      assert Attention.groups() == []
    end
  end

  describe "stuck runs" do
    test "a running operation past its timeout with a dead owner is abandoned and can be closed" do
      parent = self()

      {:ok, pid} =
        Task.start(fn ->
          {:ok, run} = Operations.start_run("fetch_input_feed", "scheduled")
          send(parent, {:run, run})
        end)

      run =
        receive do
          {:run, run} -> run
        end

      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}
      refute Operations.run_owner_alive?(run)

      later = DateTime.add(run.started_at, 3600, :second)
      assert [group] = Attention.groups(later)
      assert group.kind == :stuck_run
      assert group.title == "Abandoned Feed fetch"
      assert group.action == {:close_run, run.id}

      assert {:ok, _message} = Attention.perform(group.action)
      assert Operations.get_run!(run.id).status == "failed"
      assert {:error, :run_already_finished} = Attention.perform(group.action)
      assert Attention.groups(later) == []
    end

    test "a live owner past the timeout is reported as slow with no action" do
      {:ok, run} = Operations.start_run("backfill_output_feed", "manual")
      assert Operations.run_owner_alive?(run)

      later = DateTime.add(run.started_at, 3600, :second)
      assert [group] = Attention.groups(later)
      assert group.title == "Slow Add matching articles"
      assert group.action == nil
      assert Attention.count(later) == 0
      assert Attention.groups(run.started_at) == []
    end
  end

  describe "entry failures" do
    test "a processing failure is listed until its raw item is replayed successfully" do
      {:ok, input_feed} =
        Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

      {:ok, raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: "ars-1",
          url: "https://arstechnica.com/one/",
          title: "One",
          discovered_at: ~U[2026-09-14 12:00:00Z]
        })

      {:ok, failure} =
        Operations.create_failure(%{
          failure_type: "raw_item_processing_failed",
          message: "boom",
          related: %{
            "raw_item_id" => raw_item.id,
            "input_feed_id" => input_feed.id,
            "url" => raw_item.url
          }
        })

      assert [group] = Attention.groups()
      assert group.kind == :entry_failed
      assert group.subject == "Ars"
      assert group.action == {:retry_entries, [failure.id]}

      assert {:ok, "Retried 1 of 1 entries"} = Attention.perform(group.action)
      assert Operations.get_failure!(failure.id).resolved_at
      assert Attention.groups() == []
      assert Repo.aggregate(Content.Article, :count) == 1
      assert {:error, :already_resolved} = Pipeline.retry_entry_failure(failure.id)
    end

    test "an ingestion failure retries by refetching without cache validators" do
      {:ok, input_feed} =
        Intake.create_input_feed(%{name: "Verge", url: "https://www.theverge.com/rss/index.xml"})

      {:ok, input_feed} =
        Intake.mark_input_feed_fetched(input_feed, "ok", %{etag: "\"v1\"", last_modified: "x"})

      {:ok, failure} =
        Operations.create_failure(%{
          failure_type: "raw_item_ingestion_failed",
          message: "bad guid",
          related: %{"input_feed_id" => input_feed.id, "feed_guid" => "verge-1"}
        })

      Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == []
        assert Plug.Conn.get_req_header(conn, "if-modified-since") == []
        Plug.Conn.resp(conn, 500, "")
      end)

      assert {:error, _reason} = Pipeline.retry_entry_failure(failure.id)
      assert [_feed_group, _entry_group] = Enum.sort_by(Attention.groups(), & &1.kind)
      assert Enum.any?(Attention.groups(), &(&1.kind == :feed_fetch_failed))
    end
  end

  defp feed_with_articles!(count) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for index <- 1..count do
      {:ok, _raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: "autopian-attention-#{index}",
          url: "https://www.theautopian.com/attention-#{index}/",
          title: "Article #{index}",
          discovered_at: DateTime.add(~U[2026-09-14 12:00:00Z], index, :second)
        })
    end

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, feed} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [input_feed.id]})

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    feed = Publishing.get_generated_feed!(feed.id)
    assert {:ok, _step} = Processing.create_step(feed, "extraction")
    %{feed: feed, input_feed: input_feed}
  end
end
