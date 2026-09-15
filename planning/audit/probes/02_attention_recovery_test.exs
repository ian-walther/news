defmodule Newspaper.AttentionRecoveryAuditTest do
  use Newspaper.DataCase

  alias Newspaper.{Intake, Operations, Pipeline}

  test "IMP-09 a GUID-less entry is processable while an ingestion failure is unresolved" do
    {:ok, source} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/index"
      })

    {:ok, _failure} =
      Operations.create_failure(%{
        failure_type: "raw_item_ingestion_failed",
        message: "Previous bad entry",
        related: %{"input_feed_id" => source.id, "url" => "https://arstechnica.com/missing/"}
      })

    Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
      Plug.Conn.resp(conn, 200, """
      <rss version="2.0"><channel><title>Ars Technica</title><link>https://arstechnica.com</link>
      <description>Technology</description><item><title>A useful article without a GUID</title>
      <link>https://arstechnica.com/guid-less/</link><description>Article summary.</description>
      </item></channel></rss>
      """)
    end)

    assert {:ok, _run} = Pipeline.fetch_input_feed(source, "audit")
  end

  test "IMP-10 a live operation cannot be closed as abandoned" do
    {:ok, run} = Operations.start_run("fetch_input_feed", "audit")
    assert Operations.run_owner_alive?(run)
    assert {:error, _reason} = Operations.close_run_as_failed(run.id)
  end

  test "IMP-17 a successful refetch cannot claim repair of an absent entry" do
    {:ok, source} =
      Intake.create_input_feed(%{
        name: "Ars Technica",
        url: "https://feeds.arstechnica.com/index"
      })

    {:ok, failure} =
      Operations.create_failure(%{
        failure_type: "raw_item_ingestion_failed",
        message: "Previous bad entry",
        related: %{
          "input_feed_id" => source.id,
          "feed_guid" => "expired-entry",
          "url" => "https://arstechnica.com/expired-entry/"
        }
      })

    Req.Test.stub(Newspaper.Pipeline.FeedClient, fn conn ->
      Plug.Conn.resp(conn, 200, """
      <rss version="2.0"><channel><title>Ars Technica</title><link>https://arstechnica.com</link>
      <description>Technology</description></channel></rss>
      """)
    end)

    assert {:error, _reason} = Pipeline.retry_entry_failure(failure.id)
  end
end
