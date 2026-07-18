defmodule NewspaperWeb.AdminLive.OutputFeedsCrudTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.{Intake, Publishing, Repo}
  alias Newspaper.Publishing.GeneratedFeed

  test "creates, configures, and deletes output feeds", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Source Feed",
        url: "https://example.com/source.xml"
      })

    {:ok, intake_group} =
      Intake.create_intake_group(%{
        name: "Source Group"
      })

    {:ok, index_view, _html} = live(conn, ~p"/output-feeds")

    refute has_element?(index_view, "#new-output-feed-form")

    index_view
    |> element("#add-output-feed")
    |> render_click()

    assert has_element?(index_view, "#new-output-feed-form")
    refute has_element?(index_view, "input[name='generated_feed[process_items]']")

    index_view
    |> form("#new-output-feed-form", %{
      "generated_feed" => %{
        "title" => "Cars",
        "description" => "Seeded from the FreshRSS Cars category.",
        "item_limit" => "25",
        "input_feed_ids" => [input_feed.id],
        "intake_group_ids" => []
      }
    })
    |> render_submit()

    output_feed = Repo.get_by!(GeneratedFeed, title: "Cars") |> Repo.preload(:input_feeds)
    assert output_feed.item_limit == 25
    assert Enum.map(output_feed.input_feeds, & &1.id) == [input_feed.id]
    refute has_element?(index_view, "#new-output-feed-form")
    assert has_element?(index_view, "#open-output-feed-#{output_feed.id}")

    {:ok, detail_view, _html} = live(conn, ~p"/output-feeds/#{output_feed.id}")

    assert has_element?(detail_view, "#output-feed-settings-form")
    assert has_element?(detail_view, "#processing-workspace")
    refute has_element?(detail_view, "#output-settings-link")

    detail_view
    |> form("#output-feed-settings-form", %{
      "generated_feed" => %{
        "title" => "Output Feed Updated",
        "description" => "Updated output feed",
        "item_limit" => "100",
        "enabled" => "true",
        "link_to_hosted_article" => "false",
        "title_source" => "original",
        "body_source" => "original_feed",
        "input_feed_ids" => [],
        "intake_group_ids" => [intake_group.id]
      }
    })
    |> render_submit()

    output_feed =
      output_feed.id
      |> Publishing.get_generated_feed!()
      |> Repo.preload([:input_feeds, :intake_groups], force: true)

    assert output_feed.title == "Output Feed Updated"
    assert output_feed.description == "Updated output feed"
    assert output_feed.item_limit == 100
    refute output_feed.link_to_hosted_article
    assert output_feed.input_feeds == []
    assert Enum.map(output_feed.intake_groups, & &1.id) == [intake_group.id]
    assert has_element?(detail_view, "#output-feed-heading", "Output Feed Updated")

    {:ok, index_view, _html} = live(conn, ~p"/output-feeds")

    index_view
    |> element("#delete-output-feed-#{output_feed.id}")
    |> render_click()

    refute Repo.get(GeneratedFeed, output_feed.id)
    _ = :sys.get_state(index_view.pid)
    assert_redirect(detail_view, ~p"/output-feeds")
  end

  test "keeps manual feed maintenance on the unified detail page", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_freshrss_cars_test",
        "description" => "Seeded from the FreshRSS Cars category.",
        "input_feed_ids" => [input_feed.id]
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{output_feed.id}")

    assert has_element?(view, "#backfill-output-feed")
    assert has_element?(view, "#rerender-output-feed")
  end
end
