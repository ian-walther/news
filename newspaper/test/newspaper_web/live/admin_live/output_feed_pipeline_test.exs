defmodule NewspaperWeb.AdminLive.OutputFeedPipelineTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Processing
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "configures an output feed pipeline from the admin UI", %{conn: conn} do
    {:ok, feed} =
      Publishing.create_generated_feed(%{
        "title" => "Technology Reading",
        "guid" => "feed_pipeline_ui_test",
        "process_items" => true
      })

    {:ok, view, _html} = live(conn, ~p"/output-feeds/#{feed.id}/pipeline")

    assert has_element?(view, "#new-pipeline-step-form")
    assert has_element?(view, "#process-existing-items")

    view
    |> form("#new-pipeline-step-form",
      pipeline_step: %{
        "implementation_key" => "extraction.simple_html",
        "timeout_ms" => "30000",
        "minimum_text_length" => "750"
      }
    )
    |> render_submit()

    [step] = Processing.list_steps(feed)
    assert step.config["timeout_ms"] == 30_000
    assert step.config["minimum_text_length"] == 750
    assert has_element?(view, "#steps-#{step.id}")

    view
    |> element("#edit-step-#{step.id}")
    |> render_click()

    view
    |> form("#edit-pipeline-step-form-#{step.id}",
      pipeline_step: %{
        "enabled" => "false",
        "timeout_ms" => "45000",
        "minimum_text_length" => "1000"
      }
    )
    |> render_submit()

    step = Processing.get_step!(step.id)
    refute step.enabled
    assert step.config["timeout_ms"] == 45_000

    view
    |> element("#toggle-step-#{step.id}")
    |> render_click()

    assert Processing.get_step!(step.id).enabled

    view
    |> element("#delete-step-#{step.id}")
    |> render_click()

    assert Processing.list_steps(feed) == []
    refute Repo.get(Newspaper.Processing.PipelineStep, step.id)
  end
end
