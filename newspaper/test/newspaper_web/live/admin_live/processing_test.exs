defmodule NewspaperWeb.AdminLive.ProcessingTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.PipelineStepAttempt
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "shows running, queued, waiting, and recent work in one live view", %{conn: conn} do
    %{feed: feed, running: running, queued: queued, digestion: digestion} =
      processing_fixture!()

    {:ok, batch} =
      Operations.start_run("pipeline_batch", "manual", %{
        "generated_feed_id" => feed.id,
        "generated_feed_title" => feed.title,
        "step_type" => "digestion"
      })

    {:ok, batch} =
      Operations.finish_run(batch, "succeeded", %{
        summary_counts: %{"total" => 4, "succeeded" => 4}
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#processing-tab-queue[aria-current='page']")
    assert has_element?(view, "#stage-card-extraction", "Counts executions")
    assert has_element?(view, "#stage-card-digestion")
    assert has_element?(view, "#article-health", "3 articles")
    assert has_element?(view, "#running-attempt-#{running.id}", "Extraction")
    assert has_element?(view, "#queued-extraction-extraction-#{queued.id}")
    assert has_element?(view, "#queued-digestion-digestion-#{digestion.id}")

    assert has_element?(
             view,
             "#waiting-blocked-digestion-#{feed.id}",
             "Waiting for article extraction"
           )

    refute has_element?(view, "#recent-run-#{batch.id}")

    assert {:ok, digestion} = Processing.mark_attempt_running(digestion)
    refresh_processing(view)

    refute has_element?(view, "#queued-digestion-digestion-#{digestion.id}")
    assert has_element?(view, "#running-attempt-#{digestion.id}", "Digestion")

    assert {:ok, _digestion} = Processing.finish_attempt(digestion, "succeeded")
    refresh_processing(view)

    refute has_element?(view, "#running-attempt-#{digestion.id}")

    assert has_element?(
             view,
             "#completed-attempt-#{digestion.id}",
             "The article ready for digestion"
           )

    assert has_element?(view, "#recently-processed-link[href='/articles?sort=recent']")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=history")
    assert has_element?(view, "#recent-run-#{batch.id}", "Digestion batch")
    assert has_element?(view, "#recent-attempt-#{digestion.id}", "Digestion")
  end

  test "history filters every status by output and stage and honours legacy context links", %{
    conn: conn
  } do
    %{feed: feed, running: running, digestion: digestion} = processing_fixture!()

    {:ok, view, _html} =
      live(conn, ~p"/processing?stage=digestion&generated_feed_id=#{feed.id}")

    assert has_element?(view, "#processing-tab-history[aria-current='page']")
    assert has_element?(view, "#processing-stage-digestion.btn-active")
    assert has_element?(view, "#processing-filter option[selected]", feed.title)
    refute has_element?(view, "#recent-attempt-#{running.id}")
    assert has_element?(view, "#recent-attempt-#{digestion.id}", "Queued")

    {:ok, view, _html} = live(conn, ~p"/processing?article_id=#{running.article_id}")
    assert has_element?(view, "#processing-context", "Article ##{running.article_id}")
    assert has_element?(view, "#recent-attempt-#{running.id}", "Running")
    refute has_element?(view, "#recent-attempt-#{digestion.id}")
  end

  test "pauses and resumes digestion from the queue and reflects changes made elsewhere", %{
    conn: conn
  } do
    processing_fixture!()
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#digestion-runtime-status[data-state='running']")
    view |> element("#toggle-digestion-pause") |> render_click()

    settings = Operations.get_settings()
    assert settings.digestion_paused
    assert settings.ollama_model == "qwen3.6:27b"
    assert has_element?(view, "#digestion-runtime-status[data-state='paused']")
    assert has_element?(view, "#digestion-queue-state", "Paused")
    assert has_element?(view, "#stage-eta-digestion", "paused")

    assert {:ok, _settings} = Operations.update_settings(settings, %{digestion_paused: false})
    refresh_processing(view)

    assert has_element?(view, "#digestion-runtime-status[data-state='running']")
    refute has_element?(view, "#digestion-queue-state")
  end

  test "shows website pacing state with a single Try now", %{conn: conn} do
    processing_fixture!()

    {:ok, policy} =
      Newspaper.Content.create_site_extraction_policy(%{
        site_host: "racer.com",
        consecutive_rate_limits: 3,
        backoff_until: DateTime.add(DateTime.utc_now(:second), 15 * 60, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#host-racer-com[data-state='backoff']", "0 queued")
    assert has_element?(view, "#host-theautopian-com[data-state='running']", "1 queued")
    assert has_element?(view, "#retry-site-now-#{policy.id}", "Try now")

    view |> element("#retry-site-now-#{policy.id}") |> render_click()
    assert has_element?(view, "#flash-info", "No queued articles for racer.com")
  end

  test "renders completed recovered attempts without a start timestamp", %{conn: conn} do
    %{digestion: digestion} = processing_fixture!()

    digestion
    |> PipelineStepAttempt.changeset(%{
      status: "succeeded",
      started_at: nil,
      finished_at: ~U[2026-07-19 20:18:36Z],
      error_message: "Application restarted while attempt was running"
    })
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/processing?tab=history")

    assert has_element?(view, "#recent-attempt-#{digestion.id}", "Duration unavailable")
  end

  test "coalesces bursts of processing events into one queued refresh", %{conn: conn} do
    %{digestion: digestion} = processing_fixture!()
    {:ok, view, _html} = live(conn, ~p"/processing")

    assert has_element?(view, "#processing-tab-queue[aria-current='page']")
    assert has_element?(view, "#queued-digestion-digestion-#{digestion.id}")
    assert {:ok, digestion} = Processing.mark_attempt_running(digestion)

    for _index <- 1..10 do
      send(view.pid, {:newspaper_data_changed, :processing_changed})
    end

    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#queued-digestion-digestion-#{digestion.id}")
    refute has_element?(view, "#running-attempt-#{digestion.id}")

    send(view.pid, :refresh_processing_data)
    _ = :sys.get_state(view.pid)

    refute has_element?(view, "#queued-digestion-digestion-#{digestion.id}")
    assert has_element?(view, "#running-attempt-#{digestion.id}")
  end

  defp refresh_processing(view) do
    send(view.pid, :refresh_processing_data)
    _ = :sys.get_state(view.pid)
  end

  defp processing_fixture! do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    for {guid, path, title, published_at} <- [
          {"autopian-running", "running-extraction", "The extraction currently running",
           ~U[2026-07-18 12:00:00Z]},
          {"autopian-queued", "queued-extraction", "The extraction queued behind it",
           ~U[2026-07-18 11:00:00Z]},
          {"autopian-digest", "queued-digestion", "The article ready for digestion",
           ~U[2026-07-18 10:00:00Z]}
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

    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_processing_visibility_test",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    assert {:ok, _step} = Processing.create_extraction_step(feed)

    settings = Operations.get_settings()
    assert {:ok, _settings} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
    assert {:ok, _step} = Processing.create_digest_step(feed)

    [running_item, queued_item, digestion_item] = Publishing.list_items_for_feed(feed)

    assert {:ok, [running]} = Processing.request_item_step(running_item, "extraction")
    assert {:ok, running} = Processing.mark_attempt_running(running)
    assert {:ok, [queued]} = Processing.request_item_step(queued_item, "extraction")

    insert_extraction!(digestion_item.article)
    digestion_item = Publishing.list_items_for_feed(feed) |> List.last()
    assert {:ok, [digestion]} = Processing.request_item_step(digestion_item, "digestion")

    assert Repo.get!(PipelineStepAttempt, digestion.id).step_type == "digestion"

    %{feed: feed, running: running, queued: queued, digestion: digestion}
  end

  defp insert_extraction!(article) do
    %ArticleExtraction{}
    |> ArticleExtraction.changeset(%{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      final_url: article.canonical_url,
      title: article.title,
      content_html: "<p>Extracted article body.</p>",
      content_text: "Extracted article body.",
      extracted_at: ~U[2026-07-18 12:00:00Z]
    })
    |> Repo.insert!()

    article
    |> Article.changeset(%{extraction_status: "succeeded"})
    |> Repo.update!()
  end
end
