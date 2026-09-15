defmodule NewspaperWeb.PageControllerTest do
  use NewspaperWeb.ConnCase

  test "GET / is the processing queue", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)
    assert html =~ ~s(id="article-health")
    assert html =~ ~s(id="queue-tab")
  end

  test "removed routes are gone", %{conn: conn} do
    for path <- ["/sites", "/runs"] do
      assert get(conn, path).status == 404
    end
  end
end
