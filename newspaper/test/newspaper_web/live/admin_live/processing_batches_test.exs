defmodule NewspaperWeb.AdminLive.ProcessingBatchesTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Intake
  alias Newspaper.Operations
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{BatchDispatcher, PipelineStepAttempt}
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "lists batches across feeds running-first with member-based progress", %{conn: conn} do
    %{feed_a: feed_a, feed_b: feed_b} = two_feeds!(3)
    assert {:ok, old} = Processing.start_feed_batch(feed_b.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(old.id)
    assert {:ok, _result} = Processing.cancel_feed_batch(old.id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=batches")
    assert has_element?(view, "#batch-#{old.id}[data-status='cancelled']", "Autos")

    assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    refresh(view)

    assert has_element?(view, "#batch-#{batch.id}[data-status='running']", "Cars")
    assert has_element?(view, "#batch-progress-#{batch.id}", "0 of 3")

    html = render(view)
    running_at = :binary.match(html, "id=\"batch-#{batch.id}\"") |> elem(0)
    old_at = :binary.match(html, "id=\"batch-#{old.id}\"") |> elem(0)
    assert running_at < old_at

    [attempt | _rest] = Processing.list_attempts_for_batch(batch.id)
    assert {:ok, _attempt} = Processing.finish_attempt(attempt, "succeeded")
    refresh(view)
    assert has_element?(view, "#batch-progress-#{batch.id}", "1 of 3")
  end

  test "cancels a running batch from the list", %{conn: conn} do
    %{feed_a: feed_a} = two_feeds!(2)
    assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=batches")
    view |> element("#cancel-batch-#{batch.id}") |> render_click()

    assert has_element?(view, "#flash-info", "Cancelled 2 items")
    assert has_element?(view, "#batch-#{batch.id}[data-status='cancelled']")
    refute has_element?(view, "#cancel-batch-#{batch.id}")
    assert Operations.get_run!(batch.id).status == "cancelled"
    assert Enum.all?(Repo.all(PipelineStepAttempt), &(&1.status == "skipped"))
  end

  test "links a batch to its attempts in history", %{conn: conn} do
    %{feed_a: feed_a} = two_feeds!(1)
    assert {:ok, batch} = Processing.start_feed_batch(feed_a.id, "test", "extraction")
    assert :ok = BatchDispatcher.await(batch.id)
    [attempt] = Processing.list_attempts_for_batch(batch.id)

    {:ok, view, _html} = live(conn, ~p"/processing?tab=batches")
    view |> element("#batch-attempts-#{batch.id}") |> render_click()

    assert has_element?(view, "#processing-tab-history[aria-current='page']")
    assert has_element?(view, "#processing-context", "Batch ##{batch.id}")
    assert has_element?(view, "#recent-attempt-#{attempt.id}")
  end

  defp refresh(view) do
    send(view.pid, :refresh_processing_data)
    _ = :sys.get_state(view.pid)
  end

  defp two_feeds!(count) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for index <- 1..count do
      {:ok, _raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: "autopian-batches-#{index}",
          url: "https://www.theautopian.com/batches-#{index}/",
          title: "Article #{index}",
          discovered_at: DateTime.add(~U[2026-09-14 12:00:00Z], index, :second)
        })
    end

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, feed_a} =
      Publishing.create_generated_feed(%{"title" => "Cars", "input_feed_ids" => [input_feed.id]})

    {:ok, feed_b} =
      Publishing.create_generated_feed(%{"title" => "Autos", "input_feed_ids" => [input_feed.id]})

    assert {:ok, _run} = Pipeline.backfill_output_feed(feed_a.id, "test")
    assert {:ok, _run} = Pipeline.backfill_output_feed(feed_b.id, "test")
    feed_a = Publishing.get_generated_feed!(feed_a.id)
    feed_b = Publishing.get_generated_feed!(feed_b.id)
    assert {:ok, _step} = Processing.create_step(feed_a, "extraction")
    assert {:ok, _step} = Processing.create_step(feed_b, "extraction")
    %{feed_a: feed_a, feed_b: feed_b}
  end
end
