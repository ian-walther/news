defmodule Newspaper.ProcessingBatchTest do
  use Newspaper.DataCase

  alias Newspaper.Extraction
  alias Newspaper.Content.Article
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Operations.Run
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{BatchDispatcher, GeneratedFeedItemStep, PipelineStepAttempt}
  alias Newspaper.Publishing
  alias Newspaper.Repo

  setup do
    original_config = Application.get_env(:newspaper, :extractors)

    on_exit(fn ->
      Application.put_env(:newspaper, :extractors, original_config)
    end)

    :ok
  end

  test "enabling a step materializes bookkeeping rows for existing feed items" do
    feed = extraction_feed_with_articles!()

    item_steps = Repo.all(GeneratedFeedItemStep)
    assert length(item_steps) == 2
    assert Enum.all?(item_steps, &(&1.status == "not_requested"))

    [step] = Processing.list_steps(feed.id)
    assert Processing.feed_step_counts(feed.id)[step.id].not_requested == 2
  end

  test "tracks a feed extraction batch from queue through completion" do
    feed = extraction_feed_with_articles!()
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    batch = start_feed_batch_and_wait!(feed)
    assert batch.run_type == "pipeline_batch"
    assert batch.status == "running"

    assert batch.summary_counts == %{
             "failed" => 0,
             "items_considered" => 2,
             "queued" => 2,
             "running" => 0,
             "skipped" => 0,
             "succeeded" => 0,
             "total" => 2
           }

    attempts = Repo.all(PipelineStepAttempt)
    assert length(attempts) == 2
    assert Enum.all?(attempts, &(&1.batch_run_id == batch.id))

    [first, second] = Enum.sort_by(attempts, & &1.id)
    assert {:ok, _attempt} = Extraction.execute_attempt(first.id)

    batch = Repo.get!(Run, batch.id)
    assert batch.status == "running"
    assert batch.summary_counts["succeeded"] == 1
    assert batch.summary_counts["queued"] == 1

    assert {:ok, _attempt} = Extraction.execute_attempt(second.id)

    batch = Repo.get!(Run, batch.id)
    assert batch.status == "succeeded"
    assert batch.summary_counts["succeeded"] == 2
    assert batch.summary_counts["queued"] == 0
    assert batch.finished_at
  end

  test "a later batch excludes articles that already have successful extraction" do
    feed = extraction_feed_with_articles!()
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    first_batch = start_feed_batch_and_wait!(feed)

    first_batch.id
    |> Processing.list_attempts_for_batch()
    |> Enum.each(fn attempt ->
      assert {:ok, _attempt} = Extraction.execute_attempt(attempt.id)
    end)

    second_batch = start_feed_batch_and_wait!(feed)
    assert second_batch.status == "succeeded"
    assert second_batch.summary_counts["items_considered"] == 0
    assert second_batch.summary_counts["total"] == 0
    assert second_batch.summary_counts["skipped"] == 0
    assert Processing.list_attempts_for_batch(second_batch.id) == []
  end

  test "no-content extraction attempts count as skipped without failing the batch" do
    feed = extraction_feed_with_articles!()

    no_content_payload = %{
      schema_version: 1,
      status: "no_content",
      final_url: "https://www.theautopian.com/video-only-post/",
      reason: "boilerplate_only",
      message: "boilerplate_only",
      quality: %{"score" => 0, "reason" => "boilerplate_only", "content_length" => 0},
      debug_metadata: %{"content_length" => 0}
    }

    simple_worker =
      worker_script!(Map.put(no_content_payload, :implementation, "extraction.simple_html"))

    headless_worker =
      worker_script!(Map.put(no_content_payload, :implementation, "extraction.headless_browser"))

    headed_worker =
      worker_script!(Map.put(no_content_payload, :implementation, "extraction.headed_browser"))

    Application.put_env(:newspaper, :extractors,
      simple_html_command: simple_worker,
      headless_browser_command: headless_worker,
      headed_browser_command: headed_worker
    )

    batch = start_feed_batch_and_wait!(feed)

    batch.id
    |> Processing.list_attempts_for_batch()
    |> Enum.each(fn attempt ->
      assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
      assert attempt.status == "skipped"
    end)

    batch = Repo.get!(Run, batch.id)
    assert batch.status == "succeeded"
    assert batch.summary_counts["failed"] == 0
    assert batch.summary_counts["skipped"] == 2
    assert batch.summary_counts["succeeded"] == 0
  end

  test "a batch skips terminal article failures while preserving manual retry" do
    feed = extraction_feed_with_articles!()

    [missing_article, pending_article] =
      Article
      |> order_by([article], asc: article.id)
      |> Repo.all()

    missing_article
    |> Article.changeset(%{
      extraction_status: "failed",
      extraction_metadata: %{
        "failure_kind" => "not_found",
        "retryable" => false,
        "message" => "HTTP 404"
      }
    })
    |> Repo.update!()

    assert Processing.feed_processing_counts(feed.id) == %{
             items: 2,
             extracted: 0,
             unavailable: 0,
             not_requested: 2
           }

    batch = start_feed_batch_and_wait!(feed)

    assert Processing.feed_processing_counts(feed.id) == %{
             items: 2,
             extracted: 0,
             unavailable: 1,
             not_requested: 0
           }

    assert batch.summary_counts["items_considered"] == 2
    assert batch.summary_counts["total"] == 1
    assert batch.summary_counts["skipped"] == 1

    [attempt] = Processing.list_attempts_for_batch(batch.id)
    assert attempt.article_id == pending_article.id

    assert {:ok, 1} = Processing.enqueue_article(missing_article.id)
  end

  test "batch enrollment survives the initiating caller exiting" do
    article_count = 40
    feed = extraction_feed_with_article_count!(article_count)
    Newspaper.Events.subscribe()
    parent = self()

    {caller, caller_ref} =
      spawn_monitor(fn ->
        result = Processing.start_feed_batch(feed.id, "test")
        send(parent, {:batch_start_result, result})
      end)

    assert_receive {:newspaper_data_changed, :operations_changed}

    if Process.alive?(caller), do: Process.exit(caller, :kill)
    assert_receive {:DOWN, ^caller_ref, :process, ^caller, reason}
    assert reason in [:normal, :killed]

    assert_receive {:newspaper_data_changed, :operations_changed}, 5_000

    [batch] = Processing.list_feed_batches(feed.id)
    assert :ok = BatchDispatcher.await(batch.id)
    batch = Repo.get!(Run, batch.id)
    assert length(Processing.list_attempts_for_batch(batch.id)) == article_count
    assert batch.summary_counts["queued"] == article_count
  end

  test "recovers durable batch enrollment left running by an application restart" do
    feed = extraction_feed_with_articles!()
    [step] = Processing.list_enabled_steps(feed.id, "extraction")

    assert {:ok, batch} =
             Operations.start_run(
               "pipeline_batch",
               "test",
               %{
                 "batch_type" => "process_existing_extraction",
                 "generated_feed_id" => feed.id,
                 "generated_feed_title" => feed.title,
                 "step_type" => "extraction"
               },
               %{"pipeline_step_ids" => [step.id]}
             )

    Newspaper.Events.subscribe()
    assert {:ok, 1} = BatchDispatcher.recover()
    assert :ok = BatchDispatcher.await(batch.id)
    assert_receive {:newspaper_data_changed, :operations_changed}

    batch = Repo.get!(Run, batch.id)
    assert batch.summary_counts["items_considered"] == 2
    assert length(Processing.list_attempts_for_batch(batch.id)) == 2
  end

  test "closes a durable batch when its saved enrollment context is invalid" do
    assert {:ok, batch} =
             Operations.start_run(
               "pipeline_batch",
               "test",
               %{"batch_type" => "process_existing_digestion"}
             )

    assert {:ok, 1} = BatchDispatcher.recover()
    assert :ok = BatchDispatcher.await(batch.id)

    batch = Repo.get!(Run, batch.id)
    assert batch.status == "failed"
    assert batch.error_summary == ":invalid_batch_context"
    assert batch.finished_at
  end

  test "a failed-only digestion batch creates fresh attempts and preserves failure history" do
    feed = digestion_feed_with_articles!()
    initial_batch = start_feed_batch_and_wait!(feed, "digestion")
    [failed_attempt, skipped_attempt] = Processing.list_attempts_for_batch(initial_batch.id)

    assert {:ok, failed_attempt} =
             Processing.finish_attempt(failed_attempt, "failed", %{
               failure_kind: "configuration_error",
               retryable: false,
               error_message: "No Ollama model is configured"
             })

    assert {:ok, _skipped_attempt} =
             Processing.finish_attempt(skipped_attempt, "skipped", %{
               error_message: "No article content"
             })

    retry_batch =
      start_feed_batch_and_wait!(feed, "digestion", selection: :failed)

    assert retry_batch.related["selection"] == "failed"
    assert retry_batch.summary_counts["items_considered"] == 1

    [retry_attempt] = Processing.list_attempts_for_batch(retry_batch.id)
    assert retry_attempt.article_id == failed_attempt.article_id
    assert retry_attempt.id != failed_attempt.id
    assert retry_attempt.status == "queued"
    assert retry_attempt.input_snapshot["request"]["retry_origin"] == "manual_batch"

    preserved_attempt = Repo.get!(PipelineStepAttempt, failed_attempt.id)
    assert preserved_attempt.status == "failed"
    assert preserved_attempt.failure_kind == "configuration_error"
    assert preserved_attempt.error_message == "No Ollama model is configured"
  end

  defp extraction_feed_with_articles! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    for {guid, path, title, published_at} <- [
          {"autopian-headlights", "round-or-rectangular-headlights",
           "Round or rectangular headlights?", ~U[2026-07-15 14:00:00Z]},
          {"autopian-trucks", "crew-cab-pickup-trucks", "The crew cab that added no seats",
           ~U[2026-07-15 13:00:00Z]}
        ] do
      {:ok, _raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: guid,
          url: "https://www.theautopian.com/#{path}/",
          title: title,
          published_at: published_at,
          body: "<p>Original feed body.</p>",
          source_name: "The Autopian",
          source_url: "https://www.theautopian.com/",
          discovered_at: DateTime.add(published_at, 60, :second)
        })
    end

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_processing_batch_test",
        "input_feed_ids" => [input_feed.id]
      })

    {:ok, step} =
      Processing.create_extraction_step(output_feed)

    {:ok, step} = Processing.update_step(step, %{enabled: false})
    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    {:ok, _step} = Processing.update_step(step, %{enabled: true})
    output_feed
  end

  defp extraction_feed_with_article_count!(count) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Verge",
        outlet_name: "The Verge",
        url: "https://www.theverge.com/rss/index.xml"
      })

    Enum.each(1..count, fn index ->
      published_at = DateTime.add(~U[2026-07-18 14:00:00Z], -index * 60, :second)

      assert {:ok, _raw_item} =
               Intake.upsert_raw_item(input_feed, %{
                 feed_guid: "verge-batch-#{index}",
                 url: "https://www.theverge.com/tech/batch-#{index}",
                 title: "Technology article #{index}",
                 published_at: published_at,
                 body: "<p>Original technology feed body.</p>",
                 source_name: "The Verge",
                 source_url: "https://www.theverge.com/",
                 discovered_at: DateTime.add(published_at, 60, :second)
               })
    end)

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology",
        "guid" => "feed_batch_caller_exit_test",
        "input_feed_ids" => [input_feed.id]
      })

    {:ok, step} = Processing.create_extraction_step(output_feed)
    {:ok, step} = Processing.update_step(step, %{enabled: false})
    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    {:ok, _step} = Processing.update_step(step, %{enabled: true})
    output_feed
  end

  defp digestion_feed_with_articles! do
    feed = extraction_feed_with_articles!()
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    feed
    |> start_feed_batch_and_wait!()
    |> Map.fetch!(:id)
    |> Processing.list_attempts_for_batch()
    |> Enum.each(fn attempt ->
      assert {:ok, _attempt} = Extraction.execute_attempt(attempt.id)
    end)

    settings = Operations.get_settings()
    assert {:ok, _settings} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
    assert {:ok, _step} = Processing.create_digest_step(feed)
    feed
  end

  defp start_feed_batch_and_wait!(feed, step_type \\ "extraction", opts \\ []) do
    Newspaper.Events.subscribe()
    flush_operations_events()

    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", step_type, opts)
    assert :ok = BatchDispatcher.await(batch.id)
    assert_receive {:newspaper_data_changed, :operations_changed}

    Repo.get!(Run, batch.id)
  end

  defp flush_operations_events do
    receive do
      {:newspaper_data_changed, :operations_changed} -> flush_operations_events()
    after
      0 -> :ok
    end
  end

  defp worker_script!(payload) do
    path = Path.join(System.tmp_dir!(), "newspaper-batch-#{System.unique_integer([:positive])}")
    json = Jason.encode!(payload)

    File.write!(path, """
    #!/usr/bin/env bash
    cat >/dev/null
    printf '%s\\n' '#{json}'
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp success_payload do
    %{
      schema_version: 1,
      implementation: "extraction.simple_html",
      status: "ok",
      final_url: "https://www.theautopian.com/extracted-article/",
      title: "Extracted Autopian Article",
      byline: "Jason Torchinsky",
      content_html: "<article><p>Extracted article body.</p></article>",
      content_text: "Extracted article body.",
      quality: %{"score" => 1, "reason" => "sufficient_content"},
      debug_metadata: %{"fixture" => true}
    }
  end
end
