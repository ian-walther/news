defmodule Newspaper.ProcessingBatchTest do
  use Newspaper.DataCase

  alias Newspaper.Extraction
  alias Newspaper.Content.Article
  alias Newspaper.Intake
  alias Newspaper.Operations.Run
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Repo

  setup do
    original_config = Application.get_env(:newspaper, :extractors)

    on_exit(fn ->
      Application.put_env(:newspaper, :extractors, original_config)
    end)

    :ok
  end

  test "tracks a feed extraction batch from queue through completion" do
    feed = extraction_feed_with_articles!()
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test")
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

  test "a later batch skips articles that already have successful extraction" do
    feed = extraction_feed_with_articles!()
    worker = worker_script!(success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    assert {:ok, first_batch} = Processing.start_feed_batch(feed.id, "test")

    first_batch.id
    |> Processing.list_attempts_for_batch()
    |> Enum.each(fn attempt ->
      assert {:ok, _attempt} = Extraction.execute_attempt(attempt.id)
    end)

    assert {:ok, second_batch} = Processing.start_feed_batch(feed.id, "test")
    assert second_batch.status == "succeeded"
    assert second_batch.summary_counts["items_considered"] == 2
    assert second_batch.summary_counts["total"] == 0
    assert second_batch.summary_counts["skipped"] == 2
    assert Processing.list_attempts_for_batch(second_batch.id) == []
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
             unavailable: 1,
             unprocessed: 1
           }

    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test")
    assert batch.summary_counts["items_considered"] == 2
    assert batch.summary_counts["total"] == 1
    assert batch.summary_counts["skipped"] == 1

    [attempt] = Processing.list_attempts_for_batch(batch.id)
    assert attempt.article_id == pending_article.id

    assert {:ok, 1} = Processing.enqueue_article(missing_article.id)
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
        "process_items" => false,
        "input_feed_ids" => [input_feed.id]
      })

    {:ok, _step} =
      Processing.create_extraction_step(output_feed)

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    output_feed
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
