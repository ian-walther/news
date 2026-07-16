defmodule NewspaperWeb.AdminLive.RunsTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Intake
  alias Newspaper.Operations

  test "shows meaningful runs by default and can reveal low-level runs", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/arstechnica/index"
      })

    {:ok, child_run} =
      Operations.start_run("fetch_input_feed", "system", %{
        "input_feed_id" => input_feed.id,
        "url" => input_feed.url
      })

    {:ok, child_run} =
      Operations.finish_run(child_run, "succeeded", %{
        summary_counts: %{"items" => 50}
      })

    {:ok, batch} =
      Operations.start_run("pipeline_batch", "manual", %{
        "generated_feed_id" => 4,
        "generated_feed_title" => "Cars"
      })

    {:ok, batch} =
      Operations.finish_run(batch, "succeeded", %{
        summary_counts: %{
          "total" => 20,
          "succeeded" => 19,
          "failed" => 1,
          "skipped" => 3
        }
      })

    {:ok, view, _html} = live(conn, ~p"/runs")

    assert has_element?(view, "#run-#{batch.id}", "Cars")
    assert has_element?(view, "#run-#{batch.id}", "19 succeeded")
    refute has_element?(view, "#run-#{child_run.id}")
    assert has_element?(view, "#runs-scope-all")

    {:ok, all_view, _html} = live(conn, ~p"/runs?scope=all")

    assert has_element?(all_view, "#run-#{child_run.id}", "Ars Technica")
    assert has_element?(all_view, "#run-#{child_run.id}", "Fetched 50 items")
  end
end
