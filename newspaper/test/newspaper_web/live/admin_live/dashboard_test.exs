defmodule NewspaperWeb.AdminLive.DashboardTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Operations

  test "updates recent activity when pipeline data changes", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    refute html =~ "dynamic_dashboard_test"

    assert {:ok, _run} = Operations.start_run("dynamic_dashboard_test", "test")

    _ = :sys.get_state(view.pid)

    assert render(view) =~ "dynamic_dashboard_test"
  end

  test "shows retry controls and debug fields for retryable failures", %{conn: conn} do
    {:ok, failure} =
      Operations.create_failure(%{
        failure_type: "generated_feed_render_failed",
        message: "Render failed for The Autopian",
        retryable: true,
        related: %{
          "generated_feed" => "Cars",
          "url" => "https://www.theautopian.com/feed/"
        }
      })

    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#retry-failure-#{failure.id}")
    assert render(view) =~ "https://www.theautopian.com/feed/"

    assert render(view) =~ "Retry"
  end
end
