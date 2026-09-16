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
      assert group.action == {:retry_step_group, feed.id, "extraction", "http_error"}
      assert %{items: [_, _], total: 2, more?: false} = Attention.group_items(group)
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

      # Within its stage timeout the run is merely active, and the domain
      # refuses to close it even though the owner is gone.
      assert Attention.groups() == []
      assert {:error, :within_timeout} = Operations.close_run_as_failed(run.id)

      run = age_run!(run, 3600)
      assert [group] = Attention.groups()
      assert group.kind == :stuck_run
      assert group.title == "Abandoned Feed fetch"
      assert group.action == {:close_run, run.id}

      assert {:ok, _message} = Attention.perform(group.action)
      assert Operations.get_run!(run.id).status == "failed"
      assert {:error, {:close_run, :not_running}} = Attention.perform(group.action)
      assert Attention.groups() == []
    end

    test "a live owner past the timeout cannot be closed, and pipeline runs never can" do
      {:ok, run} = Operations.start_run("backfill_output_feed", "manual")
      run = age_run!(run, 3600)
      assert {:error, :owner_alive} = Operations.close_run_as_failed(run.id)

      {:ok, batch} = Operations.start_run("pipeline_batch", "manual")
      assert {:error, :not_closable} = Operations.close_run_as_failed(batch.id)
      assert {:error, :not_found} = Operations.close_run_as_failed(batch.id + 100_000)
    end

    test "an owner pid from a previous boot is never treated as alive" do
      {:ok, run} = Operations.start_run("fetch_input_feed", "scheduled")
      assert Operations.run_owner_alive?(run)

      stale = %{run | debug_metadata: Map.put(run.debug_metadata, "owner_boot", "previous-boot")}
      refute Operations.run_owner_alive?(stale)
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
      assert group.action == {:retry_entry_group, "raw_item_processing_failed", input_feed.id}

      assert %{items: [%{id: item_id, action: {:retry_entries, [item_id]}}]} =
               Attention.group_items(group)

      assert item_id == failure.id

      assert {:ok, message} = Attention.perform(group.action)
      assert message =~ "in the background"

      # The supervised retry itself, run synchronously here.
      assert {:ok, %{run: run, results: results}} = Pipeline.retry_entry_failures([failure.id])
      assert results == %{failure.id => :repaired}
      assert run.status == "succeeded"
      assert run.summary_counts["repaired"] == 1
      assert Operations.get_failure!(failure.id).resolved_at
      assert Operations.get_failure!(failure.id).retry_count == 1
      assert Attention.groups() == []
      assert Repo.aggregate(Content.Article, :count) == 1
      assert {:error, :already_resolved} = Pipeline.retry_entry_failure(failure.id)
    end

    test "a successful refetch that no longer carries the entry is not a repair" do
      {:ok, source} =
        Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

      {:ok, failure} =
        Operations.create_failure(%{
          failure_type: "raw_item_ingestion_failed",
          message: "Previous bad entry",
          related: %{"input_feed_id" => source.id, "feed_guid" => "expired-entry"}
        })

      {:ok, other} =
        Operations.create_failure(%{
          failure_type: "raw_item_ingestion_failed",
          message: "Another bad entry",
          related: %{"input_feed_id" => source.id, "feed_guid" => "also-expired"}
        })

      fetches = :counters.new(1, [])

      Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
        :counters.add(fetches, 1, 1)

        Plug.Conn.resp(conn, 200, """
        <rss version="2.0"><channel><title>Ars</title><link>https://arstechnica.com</link>
        <description>Technology</description></channel></rss>
        """)
      end)

      assert {:ok, %{run: run, results: results}} =
               Pipeline.retry_entry_failures([failure.id, other.id])

      # One refetch for the whole source, and neither record is repaired.
      assert :counters.get(fetches, 1) == 1
      assert results == %{failure.id => :entry_missing, other.id => :entry_missing}
      assert run.status == "failed"
      assert run.summary_counts["entry_missing"] == 2
      refute Operations.get_failure!(failure.id).resolved_at
      assert {:error, :entry_missing} = Pipeline.retry_entry_failure(failure.id)
    end

    test "a feed entry without a GUID is ingested while an unrelated ingestion failure is open" do
      {:ok, source} =
        Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

      {:ok, unrelated} =
        Operations.create_failure(%{
          failure_type: "raw_item_ingestion_failed",
          message: "Previous bad entry",
          related: %{"input_feed_id" => source.id, "url" => "https://arstechnica.com/missing/"}
        })

      Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
        Plug.Conn.resp(conn, 200, """
        <rss version="2.0"><channel><title>Ars</title><link>https://arstechnica.com</link>
        <description>Technology</description><item><title>A useful article without a GUID</title>
        <link>https://arstechnica.com/guid-less/</link><description>Summary.</description>
        </item></channel></rss>
        """)
      end)

      assert {:ok, run} = Pipeline.fetch_input_feed(source, "test")
      assert run.summary_counts["items"] == 1
      refute Operations.get_failure!(unrelated.id).resolved_at

      # The same fetch repairs a failure recorded for that URL.
      {:ok, by_url} =
        Operations.create_failure(%{
          failure_type: "raw_item_ingestion_failed",
          message: "Bad entry",
          related: %{"input_feed_id" => source.id, "url" => "https://arstechnica.com/guid-less/"}
        })

      assert {:ok, _run} = Pipeline.fetch_input_feed(source, "test", ignore_validators: true)
      assert Operations.get_failure!(by_url.id).resolved_at
    end

    test "re-render failures are attributable, actionable, and resolve on a later success" do
      {:ok, source} =
        Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

      {:ok, _raw} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "ars-r",
          url: "https://arstechnica.com/r/",
          title: "Render me",
          discovered_at: ~U[2026-09-14 12:00:00Z]
        })

      assert {:ok, _run} = Pipeline.process_input_feed(source.id, "test")

      {:ok, feed} =
        Publishing.create_generated_feed(%{"title" => "Tech", "input_feed_ids" => [source.id]})

      assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
      [item] = Publishing.list_items_for_feed(feed)

      {:ok, failure} =
        Operations.create_failure(%{
          failure_type: "generated_feed_item_render_failed",
          message: "title can't be blank",
          retryable: true,
          related: %{
            "generated_feed_id" => feed.id,
            "generated_feed_item_id" => item.id,
            "article_id" => item.article_id
          }
        })

      assert [group] = Attention.groups()
      assert group.kind == :entry_failed
      assert group.stage == "publishing"
      assert group.subject == "Tech"
      assert group.action == {:rerender, feed.id}
      assert Attention.count() == 1

      assert {:ok, _run} = Pipeline.rerender_output_feed(feed.id, "test")
      assert Operations.get_failure!(failure.id).resolved_at
      assert Attention.groups() == []
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

  defp age_run!(run, seconds) do
    run
    |> Ecto.Changeset.change(started_at: DateTime.add(run.started_at, -seconds, :second))
    |> Repo.update!()
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
