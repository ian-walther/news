defmodule NewspaperWeb.AdminLive.IntakeStatusTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Intake

  test "a feed whose last fetch was unchanged upstream still reads as healthy", %{conn: conn} do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "IndyCar - The Race",
        url: "https://the-race.com/category/indycar/feed/"
      })

    {:ok, feed} = Intake.mark_input_feed_fetched(feed, "not_modified")

    {:ok, view, _html} = live(conn, ~p"/intake")

    assert has_element?(view, "#input-feed-#{feed.id}", "Healthy")
    refute has_element?(view, "#input-feed-#{feed.id}", "Never fetched")
  end
end
