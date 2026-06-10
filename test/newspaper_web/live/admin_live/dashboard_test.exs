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
end
