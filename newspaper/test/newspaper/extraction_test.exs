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

    assert output_feed.use_extracted_content_body
    assert output_feed.link_to_hosted_article
  end

  test "rate limited extraction updates site backoff policy without escalating extractor capability" do
    article = create_article!("https://www.theautopian.com/example")
    worker = worker_script!("rate-limited", rate_limited_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_rate_limited_test")

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    {:ok, _policy} =
      Content.update_site_extraction_policy(policy, %{minimum_request_interval_ms: 12_000})

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
    assert policy.minimum_request_interval_ms == 12_000
    assert DateTime.diff(policy.backoff_until, policy.last_rate_limited_at, :second) in 59..60
    assert Content.backoff_active?(policy, DateTime.utc_now(:second))
    assert Content.extraction_wait_ms(policy) > 0

    failure = Repo.one!(Failure)
    assert failure.failure_type == "pipeline_step_rate_limited"
    assert {:ok, retry_attempt} = Pipeline.retry_failure(failure.id, "test_retry")
    assert retry_attempt.status == "queued"
    assert Repo.get!(Failure, failure.id).retry_count == 1
  end

  test "repeated headerless simple rate limits escalate to headless and learn it" do
    article = create_article!("https://racer.com/browser-required-example")

    simple_worker =
      worker_script!("simple-rate-limited", rate_limited_payload(article.canonical_url))

    headless_worker =
      worker_script!(
        "headless-after-rate-limit",
        success_payload()
        |> Map.put(:implementation, "extraction.headless_browser")
        |> Map.put(:final_url, article.canonical_url)
      )

    Application.put_env(:newspaper, :extractors,
      simple_html_command: simple_worker,
      headless_browser_command: headless_worker
    )

    configure_extraction!(article, "feed_rate_limit_escalation_test")

    first_attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, first_attempt} = Extraction.execute_attempt(first_attempt.id)
    assert first_attempt.status == "failed"

    assert {:ok, second_attempt} = Processing.retry_attempt(first_attempt.id)
    assert {:ok, second_attempt} = Extraction.execute_attempt(second_attempt.id)
    assert second_attempt.status == "succeeded"

    attempts =
      ArticleExtractionAttempt
      |> Repo.all()
      |> Enum.sort_by(& &1.id)

    assert Enum.map(attempts, &{&1.implementation, &1.status}) == [
             {"extraction.simple_html", "failed"},
             {"extraction.simple_html", "failed"},
             {"extraction.headless_browser", "ok"}
           ]

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.minimum_implementation == "extraction.headless_browser"
    assert policy.last_successful_implementation == "extraction.headless_browser"
    assert policy.consecutive_rate_limits == 0
    assert policy.backoff_until == nil
  end

  test "explicit retry-after does not escalate a repeated rate limit" do
    article = create_article!("https://racer.com/retry-after-example")

    simple_worker =
      worker_script!(
        "simple-retry-after",
        rate_limited_payload(article.canonical_url, 10 * 60 * 1000)
      )

    headless_worker =
      worker_script!(
        "unused-headless-retry-after",
        success_payload()
        |> Map.put(:implementation, "extraction.headless_browser")
        |> Map.put(:final_url, article.canonical_url)
      )

    Application.put_env(:newspaper, :extractors,
      simple_html_command: simple_worker,
      headless_browser_command: headless_worker
    )

    configure_extraction!(article, "feed_retry_after_no_escalation_test")

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    {:ok, _policy} =
      Content.update_site_extraction_policy(policy, %{consecutive_rate_limits: 1})

    attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, attempt} = Extraction.execute_attempt(attempt.id)
    assert attempt.status == "failed"

    assert [%ArticleExtractionAttempt{implementation: "extraction.simple_html"}] =
             Repo.all(ArticleExtractionAttempt)

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.minimum_implementation == "extraction.simple_html"
    assert policy.consecutive_rate_limits == 2
  end

  test "rate limit backoff grows to a thirty minute cap" do
    article = create_article!("https://www.theautopian.com/backoff-example")
    worker = worker_script!("repeated-rate-limit", rate_limited_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_rate_limit_backoff_test")

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)
    {:ok, _policy} = Content.update_site_extraction_policy(policy, %{escalation_enabled: false})

    first_attempt = Repo.one!(PipelineStepAttempt)

    Enum.reduce([60, 5 * 60, 15 * 60, 30 * 60, 30 * 60], first_attempt, fn seconds, attempt ->
      assert {:ok, failed_attempt} = Extraction.execute_attempt(attempt.id)
      assert failed_attempt.status == "failed"

      policy = Repo.one!(SiteExtractionPolicy)

      assert DateTime.diff(policy.backoff_until, policy.last_rate_limited_at, :second) in (seconds -
                                                                                             1)..seconds

      assert {:ok, next_attempt} = Processing.retry_attempt(failed_attempt.id)
      next_attempt
    end)
  end

  test "successful extraction clears transient backoff without changing site pacing" do
    article = create_article!("https://www.theautopian.com/recovery-example")
    rate_limited_worker = worker_script!("recovery-rate-limit", rate_limited_payload())
    Application.put_env(:newspaper, :extractors, simple_html_command: rate_limited_worker)
    configure_extraction!(article, "feed_rate_limit_recovery_test")

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    {:ok, _policy} =
      Content.update_site_extraction_policy(policy, %{minimum_request_interval_ms: 12_000})

    first_attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, failed_attempt} = Extraction.execute_attempt(first_attempt.id)

    success_worker =
      worker_script!(
        "recovery-success",
        Map.put(success_payload(), :final_url, article.canonical_url)
      )

    Application.put_env(:newspaper, :extractors, simple_html_command: success_worker)
    assert {:ok, retry_attempt} = Processing.retry_attempt(failed_attempt.id)
    assert {:ok, _attempt} = Extraction.execute_attempt(retry_attempt.id)

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.minimum_request_interval_ms == 12_000
    assert policy.consecutive_rate_limits == 0
    assert policy.backoff_until == nil
  end

  test "server retry-after can exceed the local backoff cap" do
    article = create_article!("https://www.theautopian.com/retry-after-example")

    worker =
      worker_script!(
        "retry-after-rate-limit",
        rate_limited_payload("https://www.theautopian.com/example", 45 * 60 * 1000)
      )

    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_retry_after_test")

    attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, _attempt} = Extraction.execute_attempt(attempt.id)

    policy = Repo.one!(SiteExtractionPolicy)

    retry_after_seconds = 45 * 60

    assert DateTime.diff(policy.backoff_until, policy.last_rate_limited_at, :second) in (retry_after_seconds -
                                                                                           1)..retry_after_seconds
  end

  test "escalates insufficient static HTML to headless extraction and learns the site minimum" do
    article = create_article!("https://example.com/browser-rendered-story")

    simple_worker =
      worker_script!("simple-insufficient", %{
        schema_version: 1,
        implementation: "extraction.simple_html",
        status: "failed",
        final_url: article.canonical_url,
        failure_kind: "insufficient_content",
        retryable: false,
        message: "readability_returned_no_content",
        quality: %{"score" => 0, "reason" => "readability_returned_no_content"},
        debug_metadata: %{"fixture" => true}
      })

    headless_worker =
      worker_script!(
        "headless-success",
        success_payload()
        |> Map.put(:implementation, "extraction.headless_browser")
        |> Map.put(:final_url, article.canonical_url)
      )

    Application.put_env(:newspaper, :extractors,
      simple_html_command: simple_worker,
      headless_browser_command: headless_worker
    )

    configure_extraction!(article, "feed_headless_escalation_test")

    pipeline_attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, pipeline_attempt} = Extraction.execute_attempt(pipeline_attempt.id)
    assert pipeline_attempt.status == "succeeded"

    attempts =
      ArticleExtractionAttempt
      |> Repo.all()
      |> Enum.sort_by(& &1.id)

    assert Enum.map(attempts, &{&1.implementation, &1.status}) == [
             {"extraction.simple_html", "failed"},
             {"extraction.headless_browser", "ok"}
           ]

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.minimum_implementation == "extraction.headless_browser"
    assert policy.last_successful_implementation == "extraction.headless_browser"
  end

  test "recovers a stale article permalink through a same-site URL feed GUID" do
    stale_url =
      "https://www.theautopian.com/park-outside-jeep-warns-owners-that-cars-could-catch-fire/"

    stable_url = "https://www.theautopian.com/?p=278603"

    corrected_url =
      "https://www.theautopian.com/park-outside-jeep-warns-owners-that-could-catch-fire/"

    article = create_article!(stale_url, feed_guid: stable_url)

    worker =
      fallback_worker_script!(
        stable_url,
        not_found_payload(stale_url),
        Map.put(success_payload(), :final_url, corrected_url)
      )

    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_stale_permalink_test")

    pipeline_attempt = Repo.one!(PipelineStepAttempt)
    assert {:ok, pipeline_attempt} = Extraction.execute_attempt(pipeline_attempt.id)
    assert pipeline_attempt.status == "succeeded"

    article = Repo.get!(Article, article.id)
    assert article.extraction_status == "succeeded"
    assert article.resolved_url == corrected_url

    [missing_attempt, recovered_attempt] =
      ArticleExtractionAttempt
      |> Repo.all()
      |> Enum.sort_by(& &1.id)

    assert missing_attempt.failure_kind == "http_error"
    assert missing_attempt.input_snapshot["url"] == stale_url
    assert recovered_attempt.status == "ok"
    assert recovered_attempt.input_snapshot["url"] == stable_url
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

  test "site retry now bypasses active backoff once without resetting rate limit history" do
    article = create_article!("https://retry-now.example.com/article")

    worker =
      worker_script!(
        "forced-rate-limit",
        rate_limited_payload(article.canonical_url),
        "sleep 0.1"
      )

    Application.put_env(:newspaper, :extractors, simple_html_command: worker)
    configure_extraction!(article, "feed_retry_now_test")

    {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    {:ok, _policy} =
      Content.update_site_extraction_policy(policy, %{
        consecutive_rate_limits: 1,
        backoff_until: DateTime.add(DateTime.utc_now(:second), 60 * 60, :second),
        escalation_enabled: false
      })

    attempt = Repo.one!(PipelineStepAttempt)
    Newspaper.Processing.Dispatcher.enqueue(attempt.id, policy.site_host)
    _ = :sys.get_state(Newspaper.Processing.Dispatcher)

    assert Repo.get!(PipelineStepAttempt, attempt.id).status == "queued"
    assert {:started, pid} = Newspaper.Processing.Dispatcher.retry_now(policy.site_host)

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

    attempt = Repo.get!(PipelineStepAttempt, attempt.id)
    assert attempt.status == "failed"
    assert attempt.failure_kind == "rate_limited"

    policy = Content.get_site_extraction_policy!(policy.id)
    assert policy.consecutive_rate_limits == 2

    backoff_seconds = DateTime.diff(policy.backoff_until, policy.last_rate_limited_at, :second)
    assert backoff_seconds in 299..300
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

  test "an enabled extraction step automatically queues future feed items" do
    article = create_article!("https://arstechnica.com/space/manual-example")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "guid" => "feed_manual_extraction",
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    {:ok, _step} =
      Processing.create_extraction_step(output_feed)

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    assert Repo.aggregate(PipelineStepAttempt, :count) == 1
  end

  test "a disabled extraction step leaves future feed items not requested" do
    article = create_article!("https://arstechnica.com/space/disabled-example")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "guid" => "feed_disabled_extraction",
        "input_feed_ids" => [article.representative_raw_item.input_feed_id]
      })

    {:ok, step} = Processing.create_extraction_step(output_feed)
    {:ok, _step} = Processing.update_step(step, %{enabled: false})

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    assert Repo.aggregate(PipelineStepAttempt, :count) == 0
  end

  defp create_article!(url, opts \\ []) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Seeded Feed",
        outlet_name: "Seeded Outlet",
        url: "#{url}/feed.xml"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: Keyword.get(opts, :feed_guid, "#{url}#rss"),
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

  defp fallback_worker_script!(stable_url, missing_payload, success_payload) do
    path =
      Path.join(
        System.tmp_dir!(),
        "newspaper-fallback-#{System.unique_integer([:positive])}"
      )

    missing_json = Jason.encode!(missing_payload)
    success_json = Jason.encode!(success_payload)

    File.write!(path, """
    #!/usr/bin/env bash
    request="$(cat)"

    if printf '%s' "$request" | grep -Fq '#{stable_url}'; then
      printf '%s\\n' '#{success_json}'
    else
      printf '%s\\n' '#{missing_json}'
    fi
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

  defp rate_limited_payload(url \\ "https://www.theautopian.com/example", retry_after_ms \\ nil) do
    %{
      schema_version: 1,
      implementation: "extraction.simple_html",
      status: "failed",
      final_url: url,
      failure_kind: "rate_limited",
      retryable: true,
      message: "HTTP 429",
      debug_metadata: %{"status_code" => 429, "retry_after_ms" => retry_after_ms}
    }
  end

  defp not_found_payload(url) do
    %{
      schema_version: 1,
      implementation: "extraction.simple_html",
      status: "failed",
      final_url: url,
      failure_kind: "http_error",
      retryable: false,
      message: "HTTP 404",
      debug_metadata: %{"status_code" => 404}
    }
  end
end
