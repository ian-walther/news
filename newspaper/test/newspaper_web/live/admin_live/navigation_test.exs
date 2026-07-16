defmodule NewspaperWeb.AdminLive.NavigationTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  test "marks the current admin section in the shared navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/articles")

    assert has_element?(view, "#app-nav [data-nav='articles'][aria-current='page']")
    assert has_element?(view, "#app-nav-scroll")
  end
end
