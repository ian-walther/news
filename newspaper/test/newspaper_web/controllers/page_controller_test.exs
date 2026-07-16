defmodule NewspaperWeb.PageControllerTest do
  use NewspaperWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ ~s(id="article-health")
  end
end
