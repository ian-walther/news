defmodule NewspaperWeb.AdminLive.IntakeCrudTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Intake.{InputFeed, IntakeGroup}
  alias Newspaper.Repo

  test "creates, edits, and deletes intake groups and input feeds", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/intake")

    refute has_element?(view, "#new-intake-group-form")

    view
    |> element("#add-intake-group")
    |> render_click()

    assert has_element?(view, "#new-intake-group-form")

    view
    |> form("#new-intake-group-form", %{
      "intake_group" => %{
        "name" => "Garage",
        "outlet_name" => "Garage Outlet",
        "notes" => "Original notes"
      }
    })
    |> render_submit()

    group = Repo.get_by!(IntakeGroup, name: "Garage")

    view
    |> element("#edit-group-#{group.id}")
    |> render_click()

    view
    |> form("#edit-intake-group-form-#{group.id}", %{
      "intake_group" => %{
        "name" => "Garage Updated",
        "outlet_name" => "Garage Outlet Updated",
        "notes" => "Updated notes",
        "enabled" => "true"
      }
    })
    |> render_submit()

    group = Repo.get!(IntakeGroup, group.id)
    assert group.name == "Garage Updated"
    assert group.outlet_name == "Garage Outlet Updated"
    assert group.notes == "Updated notes"

    view
    |> element("#add-input-feed")
    |> render_click()

    view
    |> form("#new-input-feed-form", %{
      "input_feed" => %{
        "name" => "Garage Feed",
        "url" => "https://example.com/garage.xml",
        "intake_group_id" => ""
      }
    })
    |> render_submit()

    feed = Repo.get_by!(InputFeed, name: "Garage Feed")
    assert is_nil(feed.intake_group_id)
    refute has_element?(view, "#new-input-feed-form")

    view
    |> element("#edit-feed-#{feed.id}")
    |> render_click()

    assert has_element?(
             view,
             "#edit-input-feed-auth-required-#{feed.id}[disabled]"
           )

    view
    |> form("#edit-input-feed-form-#{feed.id}", %{
      "input_feed" => %{
        "name" => "Garage Feed Updated",
        "url" => "https://example.com/garage-updated.xml",
        "outlet_name" => "Garage Outlet",
        "intake_group_id" => group.id,
        "enabled" => "true"
      }
    })
    |> render_submit()

    feed = Repo.get!(InputFeed, feed.id)
    assert feed.name == "Garage Feed Updated"
    assert feed.url == "https://example.com/garage-updated.xml"
    assert feed.outlet_name == "Garage Outlet"
    assert feed.intake_group_id == group.id

    view
    |> element("#delete-feed-#{feed.id}")
    |> render_click()

    refute Repo.get(InputFeed, feed.id)

    view
    |> element("#delete-group-#{group.id}")
    |> render_click()

    refute Repo.get(IntakeGroup, group.id)
    _ = :sys.get_state(view.pid)
  end
end
