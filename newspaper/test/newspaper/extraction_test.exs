defmodule Newspaper.ExtractionTest do
  use Newspaper.DataCase

  alias Newspaper.Content

  alias Newspaper.Content.{
    Article,
    ArticleExtraction,
    ArticleExtractionAttempt,
    SiteExtractionPolicy
  }

  alias Newspaper.Extraction
  alias Newspaper.Intake
  alias Newspaper.Operations.Failure
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  setup do
    original_config = Application.get_env(:newspaper, :extractors)

    on_exit(fn ->
      Application.put_env(:newspaper, :extractors, original_config)
    end)

    :ok
  end

  test "extracts an article with the simple HTML worker and re-renders configured feed items" do
    article = create_article!("https://arstechnica.com/space/example")
    worker = worker_script!("success", success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    output_feed = configure_extraction!(article, "feed_freshrss_tech_test")

    item = Repo.one!(GeneratedFeedItem)
    assert item.body_mode == "original_feed_body"

    attempt = Repo.one!(PipelineStepAttempt)
    assert attempt.status == "queued"
    assert attempt.implementation_key == "extraction.site_policy"

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    {:ok, _policy} =
      Content.update_site_extraction_policy(policy, %{
        timeout_ms: 45_000,
        minimum_text_length: 750
      })

    assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
    assert attempt.status == "succeeded"

    article = Repo.get!(Article, article.id)
    assert article.extraction_status == "succeeded"
    assert article.extracted_content =~ "Extracted article body"

    extraction = Repo.get_by!(ArticleExtraction, article_id: article.id)
    assert extraction.content_html =~ "Extracted article body"
    assert extraction.content_text == "Extracted article body."

    worker_attempt = Repo.one!(ArticleExtractionAttempt)
    assert worker_attempt.status == "ok"
    assert worker_attempt.implementation == "extraction.simple_html"
    assert worker_attempt.pipeline_step_attempt_id == attempt.id

    assert worker_attempt.input_snapshot["options"] == %{
             "minimum_text_length" => 750,
             "timeout_ms" => 45_000
           }

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.site_host == "arstechnica.com"
    assert policy.last_successful_implementation == "extraction.simple_html"
    assert policy.consecutive_rate_limits == 0

    item = Repo.get!(GeneratedFeedItem, item.id)
    assert item.body_mode == "extracted_content"
    assert item.rendered_body =~ "Extracted article body"

    assert item.rendered_link_url ==
             NewspaperWeb.Endpoint.url()
             |> URI.merge("/articles/#{article.guid}")
             |> URI.to_string()

    assert output_feed.process_items
  end

  test "rate limited extraction updates site backoff policy without escalating extractor capability" do
    article = create_article!("https://www.theautopian.com/example")
    worker = worker_script!("rate-limited", rate_limited_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_rate_limited_test")

    attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
    assert attempt.status == "failed"
    assert attempt.failure_kind == "rate_limited"

    article = Repo.get!(Article, article.id)
    assert article.extraction_status == "failed"
    assert article.extraction_metadata["failure_kind"] == "rate_limited"

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.site_host == "theautopian.com"
    assert policy.minimum_implementation == "extraction.simple_html"
    assert policy.last_failure_kind == "rate_limited"
    assert policy.consecutive_rate_limits == 1
    assert policy.rate_limit_delay_ms == 5 * 60 * 1000
    assert Content.backoff_active?(policy, DateTime.utc_now(:second))
    assert Content.extraction_wait_ms(policy) > 0

    failure = Repo.one!(Failure)
    assert failure.failure_type == "pipeline_step_rate_limited"
    assert {:ok, retry_attempt} = Pipeline.retry_failure(failure.id, "test_retry")
    assert retry_attempt.status == "queued"
    assert Repo.get!(Failure, failure.id).retry_count == 1
  end

  test "terminates a worker that exceeds its execution timeout" do
    worker = worker_script!("slow", success_payload(), "sleep 5")

    assert {:error, result, _request} =
             Newspaper.Extraction.SimpleHtmlWorker.extract("https://example.com/slow",
               command: worker,
               timeout_ms: 20_000,
               command_timeout_ms: 25
             )

    assert result["failure_kind"] == "timeout"
    assert result["retryable"]
  end

  test "paces ordinary extraction attempts per site before any rate limit response" do
    {:ok, policy} = Content.get_or_create_site_extraction_policy("arstechnica.com")
    assert Content.extraction_wait_ms(policy) == 0

    {:ok, policy} = Content.mark_site_extraction_attempted(policy)
    wait_ms = Content.extraction_wait_ms(policy)

    assert wait_ms > 0
    assert wait_ms <= 3_000

    policy =
      policy
      |> SiteExtractionPolicy.changeset(%{
        last_attempted_at: DateTime.add(DateTime.utc_now(:second), -4, :second)
      })
      |> Repo.update!()

    assert Content.extraction_wait_ms(policy) == 0
  end

  test "shares one active extraction across output feeds for the same article" do
    article = create_article!("https://arstechnica.com/space/shared-example")
    worker = worker_script!("shared-success", success_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)

    configure_extraction!(article, "feed_shared_extraction_one")
    configure_extraction!(article, "feed_shared_extraction_two")

    assert Repo.aggregate(PipelineStepAttempt, :count) == 1

    attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
    assert attempt.status == "succeeded"

    items = Repo.all(GeneratedFeedItem)
    assert length(items) == 2
    assert Enum.all?(items, &(&1.body_mode == "extracted_content"))
  end

  test "manual extraction bypasses the output feed automatic processing toggle" do
    article = create_article!("https://arstechnica.com/space/manual-example")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "guid" => "feed_manual_extraction",
        "process_items" => false,
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    {:ok, _step} =
      Processing.create_extraction_step(output_feed)

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    assert Repo.aggregate(PipelineStepAttempt, :count) == 0

    assert {:ok, 1} = Processing.enqueue_article(article.id)
    assert Repo.aggregate(PipelineStepAttempt, :count) == 1
  end

  defp create_article!(url) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Seeded Feed",
        outlet_name: "Seeded Outlet",
        url: "#{url}/feed.xml"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "#{url}#rss",
        url: url,
        title: "Seeded Article",
        published_at: ~U[2026-06-18 12:00:00Z],
        body: "<p>Original feed body.</p>",
        source_name: "Seeded Outlet",
        source_url: url,
        discovered_at: ~U[2026-06-18 12:05:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    Article
    |> Repo.get_by!(representative_raw_item_id: raw_item.id)
    |> Repo.preload(:representative_raw_item)
  end

  defp configure_extraction!(article, guid) do
    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "guid" => guid,
        "process_items" => true,
        "link_to_hosted_article" => true,
        "use_extracted_content_body" => true,
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    {:ok, _step} =
      Processing.create_extraction_step(output_feed)

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    output_feed
  end

  defp worker_script!(name, payload, prelude \\ "") do
    path = Path.join(System.tmp_dir!(), "newspaper-#{name}-#{System.unique_integer([:positive])}")
    json = Jason.encode!(payload)

    File.write!(path, """
    #!/usr/bin/env bash
    cat >/dev/null
    #{prelude}
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
      final_url: "https://arstechnica.com/space/example",
      title: "Extracted Title",
      byline: "By Example",
      published_at: "2026-06-18T12:00:00.000Z",
      content_html: "<article><p>Extracted article body.</p></article>",
      content_text: "Extracted article body.",
      quality: %{"score" => 1, "reason" => "sufficient_content"},
      debug_metadata: %{"fixture" => true}
    }
  end

  defp rate_limited_payload do
    %{
      schema_version: 1,
      implementation: "extraction.simple_html",
      status: "failed",
      final_url: "https://www.theautopian.com/example",
      failure_kind: "rate_limited",
      retryable: true,
      message: "HTTP 429",
      debug_metadata: %{"status_code" => 429}
    }
  end
end
