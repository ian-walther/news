defmodule Newspaper.PipelineFetchTest do
  use Newspaper.DataCase

  alias Newspaper.Content.Article
  alias Newspaper.Intake
  alias Newspaper.Pipeline

  setup do
    Req.Test.verify_on_exit!()
    :ok
  end

  test "a routine fetch processes only items present in that response" do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/arstechnica/index"
      })

    assert {:ok, _old_raw_item} =
             Intake.upsert_raw_item(feed, %{
               feed_guid: "old-item",
               url: "https://arstechnica.com/old-item/",
               title: "An item no longer present in the feed",
               discovered_at: ~U[2026-07-20 12:00:00Z]
             })

    response_body =
      File.read!(Path.expand("../fixtures/feeds/rss2-rich.xml", __DIR__))

    Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/rss+xml")
      |> Plug.Conn.resp(200, response_body)
    end)

    assert {:ok, run} = Pipeline.fetch_input_feed(feed, "test")
    assert run.summary_counts["items"] == 1
    assert Repo.aggregate(Article, :count) == 1
  end

  test "a feed fetch uses stored cache validators and treats not-modified as success" do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "The Verge",
        url: "https://www.theverge.com/rss/index.xml"
      })

    {:ok, feed} =
      Intake.mark_input_feed_fetched(feed, "ok", %{
        etag: "\"feed-version-42\"",
        last_modified: "Fri, 24 Jul 2026 12:00:00 GMT"
      })

    Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
      assert Plug.Conn.get_req_header(conn, "if-none-match") == ["\"feed-version-42\""]

      assert Plug.Conn.get_req_header(conn, "if-modified-since") == [
               "Fri, 24 Jul 2026 12:00:00 GMT"
             ]

      Plug.Conn.resp(conn, 304, "")
    end)

    assert {:ok, run} = Pipeline.fetch_input_feed(feed, "test")
    assert run.status == "succeeded"
    assert run.summary_counts["items"] == 0

    feed = Intake.get_input_feed!(feed.id)
    assert feed.last_fetch_status == "not_modified"
  end
end
