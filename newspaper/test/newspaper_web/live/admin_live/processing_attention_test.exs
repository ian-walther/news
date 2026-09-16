defmodule NewspaperWeb.AdminLive.ProcessingAttentionTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content
  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Operations.AttentionCounter
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.BatchDispatcher
  alias Newspaper.Publishing

  test "shows the empty state and no badge when nothing needs attention", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")

    assert has_element?(view, "#attention-empty", "Nothing needs attention")
    refute has_element?(view, "#nav-attention-badge")
    refute has_element?(view, "#attention-tab-badge")
  end

  test "groups failed steps with a retry action and clears once retried", %{conn: conn} do
    feed = feed_with_articles!(2)
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

    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")

    assert has_element?(view, "#nav-attention-badge", "1")
    assert has_element?(view, "#attention-tab-badge", "1")
    assert has_element?(view, "[data-kind='step_failed']", "Article request failed")
    assert has_element?(view, "[data-kind='step_failed']", "Cars")
    assert has_element?(view, "[data-kind='step_failed']", "2 items")

    view |> element("[data-kind='step_failed'] button", "Retry 2") |> render_click()

    assert has_element?(view, "#flash-info", "retry batch started")
    [retry] = Processing.list_running_feed_batches()
    assert :ok = BatchDispatcher.await(retry.id)
    refresh(view)
    assert has_element?(view, "#attention-empty")
    refute has_element?(view, "#nav-attention-badge")
  end

  test "offers Try now for a site in backoff and refetch for a failed feed", %{conn: conn} do
    {:ok, _policy} =
      Content.create_site_extraction_policy(%{
        site_host: "racer.com",
        consecutive_rate_limits: 3,
        backoff_until: DateTime.add(DateTime.utc_now(:second), 15 * 60, :second)
      })

    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/index"
      })

    {:ok, _feed} = Intake.mark_input_feed_fetched(feed, "failed")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")

    assert has_element?(
             view,
             "#attention-site-racer\\.com[data-kind='site_backoff']",
             "Rate limited"
           )

    assert has_element?(
             view,
             "#attention-feed-#{feed.id}[data-kind='feed_fetch_failed']",
             "Ars Technica"
           )

    assert has_element?(view, "#nav-attention-badge", "2")

    view |> element("#attention-action-site-racer\\.com") |> render_click()
    assert has_element?(view, "#flash-info", "No queued articles for racer.com")
  end

  test "a feed whose later fetch succeeded is not listed even with an old failure record", %{
    conn: conn
  } do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/index"
      })

    {:ok, _failure} =
      Operations.create_failure(%{
        failure_type: "fetch_input_feed_failed",
        message: "temporary timeout",
        retryable: true,
        related: %{"input_feed_id" => feed.id, "url" => feed.url}
      })

    {:ok, _feed} = Intake.mark_input_feed_fetched(feed, "ok")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")
    assert has_element?(view, "#attention-empty")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=history&stage=operations")
    assert has_element?(view, "#failure-records", "Feed fetch failed")
  end

  defp refresh(view) do
    send(view.pid, :refresh_processing_data)
    _ = AttentionCounter.refresh()
    _ = :sys.get_state(view.pid)
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
    feed
  end
end
