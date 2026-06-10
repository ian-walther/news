defmodule NewspaperWeb.AdminLive.OutputFeedsCrudTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.{Intake, Publishing, Repo}
  alias Newspaper.Publishing.GeneratedFeed

  test "creates, edits, and deletes output feeds", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Source Feed",
        url: "https://example.com/source.xml"
      })

    {:ok, intake_group} =
      Intake.create_intake_group(%{
        name: "Source Group"
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds")

    view
    |> form("#new-output-feed-form", %{
      "generated_feed" => %{
        "title" => "Output Feed",
        "description" => "Original output feed",
        "item_limit" => "25",
        "process_items" => "false",
        "link_to_hosted_article" => "false",
        "use_extracted_content_body" => "false",
        "input_feed_ids" => [input_feed.id],
        "intake_group_ids" => []
      }
    })
    |> render_submit()

    output_feed = Repo.get_by!(GeneratedFeed, title: "Output Feed") |> Repo.preload(:input_feeds)
    assert output_feed.item_limit == 25
    assert Enum.map(output_feed.input_feeds, & &1.id) == [input_feed.id]

    view
    |> element("#edit-output-feed-#{output_feed.id}")
    |> render_click()

    view
    |> form("#edit-output-feed-form-#{output_feed.id}", %{
      "generated_feed" => %{
        "title" => "Output Feed Updated",
        "description" => "Updated output feed",
        "item_limit" => "100",
        "enabled" => "true",
        "process_items" => "true",
        "link_to_hosted_article" => "true",
        "use_extracted_content_body" => "true",
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
    assert output_feed.process_items
    assert output_feed.link_to_hosted_article
    assert output_feed.use_extracted_content_body
    assert output_feed.input_feeds == []
    assert Enum.map(output_feed.intake_groups, & &1.id) == [intake_group.id]

    view
    |> element("#delete-output-feed-#{output_feed.id}")
    |> render_click()

    refute Repo.get(GeneratedFeed, output_feed.id)
  end
end
