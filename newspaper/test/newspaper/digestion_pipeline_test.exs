defmodule Newspaper.DigestionPipelineTest do
  use Newspaper.DataCase

  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction}
  alias Newspaper.Digestion
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineStepAttempt}
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "digestion dispatcher recovers an attempt interrupted by application restart" do
    article = extracted_article!()

    settings = Operations.get_settings()

    assert {:ok, _settings} =
             Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})

    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Restart recovery",
        "guid" => "feed_digest_restart_recovery_test",
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    assert {:ok, _step} = Processing.create_extraction_step(feed)
    assert {:ok, _step} = Processing.create_digest_step(feed)
    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")

    attempt = Repo.one!(PipelineStepAttempt)
    assert attempt.step_type == "digestion"
    assert {:ok, attempt} = Processing.mark_attempt_running(attempt)

    assert {:ok, run} =
             Operations.start_run("pipeline_step", "pipeline", %{
               "pipeline_step_attempt_id" => attempt.id,
               "step_type" => "digestion"
             })

    item_step = Repo.get_by!(GeneratedFeedItemStep, step_type: "digestion")
    assert item_step.status == "running"

    assert {:noreply, recovered_state} =
             Newspaper.Digestion.Dispatcher.handle_info(:recover, %{
               queue: :queue.new(),
               running?: true
             })

    assert :queue.to_list(recovered_state.queue) == [attempt.id]

    attempt = Repo.get!(PipelineStepAttempt, attempt.id)
    assert attempt.status == "queued"
    assert attempt.started_at == nil
    assert attempt.error_message == "Application restarted while attempt was running"

    item_step = Repo.get!(GeneratedFeedItemStep, item_step.id)
    assert item_step.status == "queued"
    assert item_step.started_at == nil
    assert item_step.error_message == "Application restarted while attempt was running"

    run = Operations.get_run!(run.id)
    assert run.status == "failed"
    assert run.finished_at
    assert run.error_summary == "Application restarted while run was in progress"
  end

  test "digests an extracted article and publishes the selected title and summary" do
    article = extracted_article!()

    settings = Operations.get_settings()

    assert {:ok, _settings} =
             Operations.update_settings(settings, %{
               ollama_base_url: "http://desktop.home:11434",
               ollama_model: "qwen3.6:27b"
             })

    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_digest_pipeline_test",
        "title_source" => "digest",
        "body_source" => "digest_summary",
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    assert {:ok, _step} = Processing.create_extraction_step(feed)
    assert {:ok, _step} = Processing.create_digest_step(feed)
    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")

    item = Repo.one!(GeneratedFeedItem)
    assert item.publication_status == "processing"

    item_steps = Processing.list_item_steps(item)

    assert Enum.map(item_steps, &{&1.step_type, &1.status}) == [
             {"extraction", "succeeded"},
             {"digestion", "queued"}
           ]

    attempt = Repo.one!(PipelineStepAttempt)
    assert attempt.step_type == "digestion"

    settings = Operations.get_settings()

    assert {:ok, _settings} =
             Operations.update_settings(settings, %{ollama_model: "gpt-oss:20b"})

    summary =
      1..120
      |> Enum.chunk_every(30)
      |> Enum.map_join("\n\n", &Enum.map_join(&1, " ", fn word -> "summary#{word}" end))

    second_summary =
      1..120
      |> Enum.chunk_every(30)
      |> Enum.map_join("\n\n", &Enum.map_join(&1, " ", fn word -> "updated#{word}" end))

    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      model = Jason.decode!(body)["model"]

      {title, generated_summary} =
        case model do
          "qwen3.6:27b" ->
            {"The Autopian explains why rectangular headlights displaced round designs.", summary}

          "gpt-oss:20b" ->
            {"Updated digest title preserves the regenerated artifact separately.",
             second_summary}

          other ->
            raise "Unexpected test model: #{inspect(other)}"
        end

      Req.Test.json(conn, %{
        "model" => model,
        "done" => true,
        "message" => %{
          "content" =>
            Jason.encode!(%{
              "title" => title,
              "summary" => generated_summary
            })
        }
      })
    end)

    assert {:ok, attempt} = Digestion.execute_attempt(attempt.id)
    assert attempt.status == "succeeded"

    digest = Repo.get_by!(ArticleDigest, article_id: article.id)
    assert digest.model == "qwen3.6:27b"
    assert digest.generated_title =~ "rectangular headlights"
    assert digest.generated_summary == summary
    refute Map.has_key?(digest.output_metadata, "message")

    digestion_step =
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "digestion"
      )

    assert digestion_step.status == "succeeded"
    assert digestion_step.article_digest_id == digest.id

    item = Repo.get!(GeneratedFeedItem, item.id)
    assert item.publication_status == "published"
    assert item.body_mode == "digest_summary"
    assert item.rendered_title == digest.generated_title
    assert item.rendered_summary == summary
    assert item.rendered_body =~ "<p>summary1"

    assert {:ok, 1} = Processing.enqueue_article_step(article.id, "digestion", force: true)

    second_attempt =
      PipelineStepAttempt
      |> where([attempt], attempt.article_id == ^article.id and attempt.step_type == "digestion")
      |> order_by([attempt], desc: attempt.id)
      |> limit(1)
      |> Repo.one!()

    assert second_attempt.id != attempt.id
    assert get_in(second_attempt.input_snapshot, ["config", "model"]) == "gpt-oss:20b"

    assert {:ok, second_attempt} = Digestion.execute_attempt(second_attempt.id)
    assert second_attempt.status == "succeeded"

    [first_digest, second_digest] =
      ArticleDigest
      |> where([digest], digest.article_id == ^article.id)
      |> order_by([digest], asc: digest.id)
      |> Repo.all()

    assert first_digest.id == digest.id
    assert first_digest.model == "qwen3.6:27b"
    assert second_digest.model == "gpt-oss:20b"

    item = Repo.get!(GeneratedFeedItem, item.id)
    assert item.rendered_title == second_digest.generated_title
    assert item.rendered_summary == second_summary

    item_step_id = digestion_step.id
    pipeline_step = Processing.get_step!(digestion_step.pipeline_step_id)
    assert {:ok, _deleted_step} = Processing.delete_step(pipeline_step)

    assert Repo.get!(PipelineStepAttempt, attempt.id).pipeline_step_id == nil
    assert Repo.get!(PipelineStepAttempt, second_attempt.id).pipeline_step_id == nil

    persisted_item_step = Repo.get!(GeneratedFeedItemStep, item_step_id)
    assert persisted_item_step.pipeline_step_id == nil
    assert persisted_item_step.article_digest_id == second_digest.id
  end

  defp extracted_article! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "autopian-headlights-digest",
        url: "https://www.theautopian.com/round-or-rectangular-headlights/",
        title: "Round or rectangular headlights?",
        published_at: ~U[2026-07-15 14:00:00Z],
        body: "<p>Original feed body.</p>",
        source_name: "The Autopian",
        source_url: "https://www.theautopian.com/",
        discovered_at: ~U[2026-07-15 14:01:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    article =
      Article
      |> Repo.get_by!(representative_raw_item_id: raw_item.id)
      |> Repo.preload(:representative_raw_item)

    _extraction =
      %ArticleExtraction{}
      |> ArticleExtraction.changeset(%{
        article_id: article.id,
        implementation_key: "extraction.simple_html",
        final_url: article.canonical_url,
        title: article.title,
        site_name: "The Autopian",
        content_html:
          "<p>Headlight design changed as vehicle packaging and regulation evolved.</p>",
        content_text: String.duplicate("Headlight design history and technical context. ", 120),
        extracted_at: ~U[2026-07-17 12:00:00Z]
      })
      |> Repo.insert!()

    article
    |> Article.changeset(%{extraction_status: "succeeded"})
    |> Repo.update!()
    |> Repo.preload([:representative_raw_item, :extraction], force: true)
  end
end
