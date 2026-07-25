defmodule Newspaper.PipelineUngroupedFeedTest do
  use NewspaperWeb.ConnCase

  alias Newspaper.{Intake, Pipeline, Publishing, Repo}
  alias Newspaper.Publishing.GeneratedFeedItem

  test "ungrouped input feeds process and publish through direct output feed membership", %{
    conn: conn
  } do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Ungrouped Test Feed",
        url: "https://example.com/feed.xml"
      })

    {:ok, generated_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Ungrouped Output",
        "guid" => "feed_ungrouped_output",
        "description" => "Regression coverage for ungrouped feed publishing.",
        "input_feed_ids" => [input_feed.id]
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "entry-1",
        url: "https://example.com/articles/entry-1",
        title: "Ungrouped Entry",
        published_at: ~U[2026-06-08 12:00:00Z],
        body: "<p>Original feed body</p>",
        summary: "<p>Original feed summary</p>",
        source_name: "Example",
        source_url: "https://example.com/",
        discovered_at: ~U[2026-06-08 12:01:00Z]
      })

    assert {:ok, run} = Pipeline.process_input_feed(input_feed.id, "test")
    assert run.status == "succeeded"

    assert run.summary_counts == %{
             "articles_seen" => 1,
             "item_failures" => 0,
             "raw_items" => 1
           }

    item = Repo.one!(GeneratedFeedItem)
    assert item.generated_feed_id == generated_feed.id
    assert item.rendered_title == "Ungrouped Entry"
    assert item.rendered_link_url == "https://example.com/articles/entry-1"
    assert item.rendered_body == "<p>Original feed body</p>"

    conn = get(conn, ~p"/feeds/feed_ungrouped_output.xml")

    assert response(conn, 200) =~ "<title>Ungrouped Output</title>"
    assert response(conn, 200) =~ "<title>Ungrouped Entry</title>"

    assert response(conn, 200) =~
             "<description>&lt;p&gt;Original feed body&lt;/p&gt;</description>"
  end
end
