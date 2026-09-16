defmodule NewspaperWeb.AdminLive.ProcessingAuditTest do
  @moduledoc "Maintained versions of the UI probes from planning/audit/02 (IMP-08..22)."

  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Operations.AttentionCounter
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.BatchDispatcher
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "IMP-08: cancelled items can be re-run from the picker and the chain menu", %{conn: conn} do
    {feed, _source} = fixture!(2)
    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=batches")
    assert has_element?(view, "#start-batch-form option[value='cancelled']")

    view |> element("#cancel-batch-#{batch.id}") |> render_click()
    assert has_element?(view, "#flash-info", "Cancelled 2 extraction")

    view |> element("#processing-tab-pipeline") |> render_click()

    assert has_element?(
             view,
             "#chain-link-#{feed.id}-extraction[data-status='cancelled']",
             "2 cancelled"
           )

    assert has_element?(
             view,
             "#run-cancelled-#{feed.id}-extraction:not([disabled])",
             "Run extraction on 2 cancelled items"
           )

    assert has_element?(view, "#run-existing-#{feed.id}-extraction[disabled]")

    view |> element("#run-cancelled-#{feed.id}-extraction") |> render_click()
    assert has_element?(view, "#flash-info", "batch started")

    [rerun] = Processing.list_running_feed_batches()
    assert rerun.related["selection"] == "cancelled"
    assert :ok = BatchDispatcher.await(rerun.id)
    assert Operations.get_run!(rerun.id).summary_counts["queued"] == 2
  end

  test "IMP-11: Queue stays reachable from a stage-filtered History and filters are visible", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/processing?tab=history&stage=digestion")
    assert has_element?(view, "#processing-context", "Digestion")

    view |> element("#processing-tab-queue") |> render_click()
    assert has_element?(view, "#queue-tab")
    assert has_element?(view, "#processing-context", "applied on Pipeline and History")

    view |> element("#clear-processing-context") |> render_click()
    refute has_element?(view, "#processing-context")
    assert has_element?(view, "#queue-tab")

    # Legacy links without a tab still land on History.
    {:ok, view, _html} = live(conn, ~p"/processing?stage=digestion")
    assert has_element?(view, "#history-tab")
  end

  test "IMP-12: expanded article history survives processing updates", %{conn: conn} do
    {feed, _source} = fixture!(1)
    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    [item] = Publishing.list_items_for_feed(feed)

    {:ok, view, _html} = live(conn, ~p"/articles")
    view |> element("#article-history-#{item.article_id} summary") |> render_click()
    assert has_element?(view, "#article-history-list-#{item.article_id}", "Queued")

    send(view.pid, {:newspaper_data_changed, :processing_changed})
    send(view.pid, :refresh_articles)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#article-history-list-#{item.article_id}", "Queued")

    [attempt] = Processing.list_attempts_for_batch(batch.id)
    assert {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    send(view.pid, :refresh_articles)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#article-history-list-#{item.article_id}", "Ready")

    view |> element("#article-history-#{item.article_id} summary") |> render_click()
    send(view.pid, :refresh_articles)
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#article-history-list-#{item.article_id}")
  end

  test "IMP-13: the navigation badge is live on every page", %{conn: conn} do
    {_feed, source} = fixture!(1)
    {:ok, view, _html} = live(conn, ~p"/intake")
    refute has_element?(view, "#nav-attention-badge")

    {:ok, _} = Intake.mark_input_feed_fetched(source, "failed")
    assert AttentionCounter.refresh() == 1
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#nav-attention-badge", "1")

    {:ok, _} = Intake.mark_input_feed_fetched(source, "ok")
    assert AttentionCounter.refresh() == 0
    _ = :sys.get_state(view.pid)
    refute has_element?(view, "#nav-attention-badge")
  end

  test "IMP-15: Queued next shows dispatch order per website with true totals", %{conn: conn} do
    {feed, source} = fixture!(1)
    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    [bulk] = Processing.list_attempts_for_batch(batch.id)

    {:ok, _} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "audit-breaking",
        url: "https://www.theautopian.com/audit-breaking/",
        title: "A new sports car arrives while the backlog is processing",
        discovered_at: ~U[2026-09-14 12:01:00Z]
      })

    {:ok, _} = Pipeline.process_input_feed(source.id, "test")

    foreground =
      Enum.find(Processing.list_processing_attempts(["queued"]), &is_nil(&1.batch_run_id))

    assert foreground
    assert bulk.id < foreground.id

    {:ok, view, html} = live(conn, ~p"/processing")
    assert has_element?(view, "#queued-extraction-host-theautopian-com", "2 queued")

    foreground_at =
      :binary.match(html, "queued-extraction-extraction-#{foreground.id}") |> elem(0)

    bulk_at = :binary.match(html, "queued-extraction-extraction-#{bulk.id}") |> elem(0)
    assert foreground_at < bulk_at
    assert has_element?(view, "#queued-extraction-extraction-#{foreground.id}", "1")
  end

  test "IMP-17: retrying entries reports background work, not a repair", %{conn: conn} do
    {:ok, source} =
      Intake.create_input_feed(%{name: "Ars", url: "https://feeds.arstechnica.com/index"})

    {:ok, failure} =
      Operations.create_failure(%{
        failure_type: "raw_item_ingestion_failed",
        message: "bad entry",
        related: %{"input_feed_id" => source.id, "feed_guid" => "gone"}
      })

    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")

    assert has_element?(
             view,
             "#attention-action-entry-raw_item_ingestion_failed-#{source.id}",
             "Retry 1"
           )

    Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
      Plug.Conn.resp(conn, 500, "")
    end)

    assert {:ok, %{results: results}} = Pipeline.retry_entry_failures([failure.id])
    assert results == %{failure.id => :still_failed}

    assert [run] =
             Enum.filter(
               Operations.list_processing_run_entries(),
               &(&1.run.run_type == "retry_entry_failures")
             )

    assert run.run.status == "failed"
    assert run.run.error_summary =~ "still_failed"
  end

  test "IMP-19: attention items name the article and link to it and its history", %{conn: conn} do
    {feed, _source} = fixture!(1)
    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    assert {:ok, _} =
             Processing.finish_attempt(attempt, "failed", %{
               failure_kind: "http_error",
               retryable: false,
               error_message: "HTTP 500"
             })

    [item] = Publishing.list_items_for_feed(feed)

    item_step =
      Repo.get_by!(Newspaper.Processing.GeneratedFeedItemStep, generated_feed_item_id: item.id)

    article = Repo.get!(Newspaper.Content.Article, item.article_id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=attention")
    group_id = "step-extraction-http_error-#{feed.id}"
    refute has_element?(view, "#attention-items-#{group_id}")
    view |> element("#attention-expand-#{group_id}") |> render_click()

    assert has_element?(
             view,
             "#attention-item-#{group_id}-#{item_step.id} a[href='/articles/#{article.guid}']",
             "Article 1"
           )

    assert has_element?(view, "#attention-item-#{group_id}-#{item_step.id}", "HTTP 500")

    view |> element("#attention-item-history-#{group_id}-#{item_step.id}") |> render_click()
    assert has_element?(view, "#history-tab")
    assert has_element?(view, "#processing-context", "Article ##{article.id}")
    assert has_element?(view, "#recent-attempt-#{attempt.id}", "Failed")
  end

  test "IMP-22: a rejected toggle keeps showing the saved state", %{conn: conn} do
    {feed, _source} = fixture!(1)
    settings = Operations.get_settings()
    {:ok, _} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
    {:ok, _} = Processing.create_step(feed, "digestion")

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")
    html = view |> element("#toggle-step-#{feed.id}-extraction") |> render_click()
    assert html =~ "Disable article digestion before disabling extraction"

    assert has_element?(
             view,
             "#toggle-step-#{feed.id}-extraction[role='switch'][aria-checked='true']",
             "On"
           )

    assert has_element?(view, "#chain-link-#{feed.id}-extraction:not([data-status='disabled'])")
  end

  test "IMP-15 (round 2): a large single-website backlog cannot hide another website's queue", %{
    conn: conn
  } do
    {feed, _source} = fixture!(201)
    [other | _] = Publishing.list_items_for_feed(feed)

    Newspaper.Content.get_article!(other.article_id)
    |> Ecto.Changeset.change(
      canonical_url: "https://arstechnica.com/audit-new-host/",
      resolved_url: "https://arstechnica.com/audit-new-host/"
    )
    |> Repo.update!()

    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)

    other_attempt =
      Enum.find(
        Processing.list_attempts_for_batch(batch.id),
        &(&1.article_id == other.article_id)
      )

    # Put the other website after every Autopian row in arrival order.
    Repo.get!(Newspaper.Processing.PipelineStepAttempt, other_attempt.id)
    |> Ecto.Changeset.change(inserted_at: DateTime.add(DateTime.utc_now(:second), 60, :second))
    |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/processing")
    assert has_element?(view, "#queued-extraction-host-arstechnica-com", "1 queued")
    assert has_element?(view, "#queued-extraction-extraction-#{other_attempt.id}")
    assert has_element?(view, "#queued-extraction-host-theautopian-com", "200 queued · showing 5")
  end

  test "IMP-12 (round 2): article history reopens before any background refresh", %{conn: conn} do
    {feed, _source} = fixture!(1)
    assert {:ok, batch} = Processing.start_feed_batch(feed.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, view, _html} = live(conn, ~p"/articles")
    selector = "#article-history-#{item.article_id} summary"

    view |> element(selector) |> render_click()
    view |> element(selector) |> render_click()
    refute has_element?(view, "#article-history-list-#{item.article_id}")
    view |> element(selector) |> render_click()
    assert has_element?(view, "#article-history-list-#{item.article_id}")

    send(view.pid, :refresh_articles)
    _ = :sys.get_state(view.pid)
    assert has_element?(view, "#article-history-list-#{item.article_id}")
  end

  test "IMP-19 (round 2): the held-items link opens exactly the withheld articles", %{conn: conn} do
    {feed, _source} = fixture!(1)
    settings = Operations.get_settings()
    {:ok, _} = Operations.update_settings(settings, %{ollama_model: "qwen3.6:27b"})
    {:ok, _} = Processing.create_step(feed, "digestion")
    [item] = Publishing.list_items_for_feed(feed)

    Repo.insert!(%Newspaper.Content.ArticleExtraction{
      article_id: item.article_id,
      implementation_key: "extraction.simple_html",
      content_html: "<p>Extracted article body.</p>",
      content_text: "Extracted article body.",
      extracted_at: DateTime.utc_now(:second)
    })

    {:ok, [attempt]} = Processing.request_item_step(item, "digestion")
    assert attempt.status == "queued"

    {:ok, feed} =
      Publishing.update_generated_feed(Publishing.get_generated_feed!(feed.id), %{
        title_source: "digest"
      })

    {:ok, _} = Pipeline.rerender_output_feed(feed.id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline")
    assert has_element?(view, "#held-items-#{feed.id}", "1 held")

    {:ok, articles, _html} =
      view |> element("#held-items-#{feed.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(articles, "#articles-held-filter")
    assert has_element?(articles, "#article-#{item.article_id}")
  end

  defp fixture!(count) do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for index <- 1..count do
      {:ok, _} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "audit-#{index}",
          url: "https://www.theautopian.com/audit-#{index}/",
          title: "Article #{index}",
          discovered_at: DateTime.add(~U[2026-09-14 12:00:00Z], index, :second)
        })
    end

    {:ok, _} = Pipeline.process_input_feed(source.id, "test")

    {:ok, feed} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [source.id]})

    {:ok, _} = Pipeline.backfill_output_feed(feed.id, "test")
    feed = Publishing.get_generated_feed!(feed.id)
    {:ok, _} = Processing.create_step(feed, "extraction")
    {feed, source}
  end
end
