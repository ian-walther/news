defmodule NewspaperWeb.AdminLive.NavigationTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  test "marks the current admin section in the shared navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/articles")

    assert has_element?(view, "#app-nav [data-nav='articles'][aria-current='page']")
    assert has_element?(view, "#app-nav-scroll")
  end

  test "navigation has five sections and Processing is home", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    keys =
      ~r/data-nav="([^"]+)"/
      |> Regex.scan(view |> element("#app-nav-scroll") |> render())
      |> Enum.map(fn [_match, key] -> key end)

    assert keys == ["processing", "intake", "output-feeds", "articles", "settings"]
    assert has_element?(view, "#app-nav [data-nav='processing'][aria-current='page']")
  end

  describe "route matrix" do
    @routes [
      {"/", "queue-tab"},
      {"/processing", "queue-tab"},
      {"/processing?tab=queue", "queue-tab"},
      {"/processing?tab=batches", "batches-tab"},
      {"/processing?tab=attention", "attention-tab"},
      {"/processing?tab=pipeline", "pipeline-tab"},
      {"/processing?tab=history", "history-tab"},
      {"/processing?tab=nonsense", "queue-tab"},
      {"/processing?stage=digestion", "history-tab"},
      {"/processing?article_id=999999", "history-tab"},
      {"/processing?batch_run_id=999999&generated_feed_id=999999", "history-tab"},
      {"/processing?tab=pipeline&generated_feed_id=999999", "pipeline-tab"},
      {"/intake", "website-policies"},
      {"/output-feeds", "app-nav"},
      {"/articles", "articles"},
      {"/articles?sort=recent", "articles"},
      {"/settings", "settings-form"}
    ]

    test "every entry point renders on an empty database, including deleted targets", %{
      conn: conn
    } do
      Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
        Req.Test.json(conn, %{"models" => []})
      end)

      for {path, marker} <- @routes do
        {:ok, view, _html} = live(conn, path)
        assert has_element?(view, "##{marker}"), "#{path} should render ##{marker}"
      end
    end

    test "tabs switch in place and keep feed context", %{conn: conn} do
      {:ok, feed} = Newspaper.Publishing.create_generated_feed(%{"title" => "Cars"})
      {:ok, view, _html} = live(conn, ~p"/processing?tab=pipeline&generated_feed_id=#{feed.id}")

      for tab <- ~w(queue batches attention pipeline history) do
        view |> element("#processing-tab-#{tab}") |> render_click()
        assert has_element?(view, "#processing-tab-#{tab}[aria-current='page']")
        assert has_element?(view, "##{tab}-tab")
      end

      assert has_element?(view, "#processing-filter option[selected]", "Cars")
    end
  end
end
