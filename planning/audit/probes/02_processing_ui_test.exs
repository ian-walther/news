defmodule Newspaper.ProcessingUIAuditTest do
  use NewspaperWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Newspaper.{Intake, Pipeline, Processing, Publishing}
  alias Newspaper.Processing.BatchDispatcher

  test "IMP-08 the batch picker exposes cancelled items", %{conn: conn} do
    {:ok, view, _} = live(conn, "/processing?tab=batches")
    assert has_element?(view, "#start-batch-form option[value='cancelled']")
  end

  test "IMP-11 Queue remains reachable from a stage-filtered History", %{conn: conn} do
    {:ok, view, _} = live(conn, "/processing?tab=history&stage=digestion")
    view |> element("#processing-tab-queue") |> render_click()
    assert has_element?(view, "#queue-tab")
  end

  test "IMP-12 expanded article history survives ordinary processing updates", %{conn: conn} do
    {feed, _source} = fixture!()
    {:ok, batch} = Processing.start_feed_batch(feed.id, "audit", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, view, _} = live(conn, "/articles")
    view |> element("#article-history-#{item.article_id} summary") |> render_click()
    assert has_element?(view, "#article-history-list-#{item.article_id}")
    send(view.pid, {:newspaper_data_changed, :processing_changed})
    render(view)
    assert has_element?(view, "#article-history-list-#{item.article_id}")
  end

  test "IMP-13 Sources navigation badge updates when a feed failure appears", %{conn: conn} do
    {_feed, source} = fixture!()
    {:ok, view, _} = live(conn, "/intake")
    refute has_element?(view, "#nav-attention-badge")
    {:ok, _} = Intake.mark_input_feed_fetched(source, "failed")
    send(view.pid, {:newspaper_data_changed, :intake_changed})
    render(view)
    assert has_element?(view, "#nav-attention-badge", "1")
  end

  test "IMP-15 Queued next places foreground work ahead of older bulk work", %{conn: conn} do
    {feed, source} = fixture!()
    {:ok, batch} = Processing.start_feed_batch(feed.id, "audit", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    [bulk] = Processing.list_attempts_for_batch(batch.id)

    {:ok, _} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "audit-breaking",
        url: "https://www.theautopian.com/audit-breaking/",
        title: "A new sports car arrives while the backlog is processing",
        discovered_at: ~U[2026-09-14 12:01:00Z]
      })

    {:ok, _} = Pipeline.process_input_feed(source.id, "audit")
    attempts = Processing.list_processing_attempts(["queued"])
    foreground = Enum.find(attempts, &is_nil(&1.batch_run_id))
    assert foreground
    assert bulk.id < foreground.id

    {:ok, view, _} = live(conn, "/processing")
    # The stream's first child is its hidden empty state.
    assert has_element?(view, "#queued-extraction > :nth-child(2)[id$='-#{foreground.id}']")
  end

  defp fixture! do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    {:ok, _} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "audit-history",
        url: "https://www.theautopian.com/audit-history/",
        title: "An old sports car with a newly rebuilt transmission",
        discovered_at: ~U[2026-09-14 12:00:00Z]
      })

    {:ok, _} = Pipeline.process_input_feed(source.id, "audit")

    {:ok, feed} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [source.id]})

    {:ok, _} = Pipeline.backfill_output_feed(feed.id, "audit")
    {:ok, _} = Processing.create_step(feed, "extraction")
    {feed, source}
  end
end
