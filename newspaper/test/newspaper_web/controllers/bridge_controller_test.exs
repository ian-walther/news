defmodule NewspaperWeb.BridgeControllerTest do
  use NewspaperWeb.ConnCase

  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Publishing
  alias Newspaper.Repo

  @window "since=2026-09-30T00:00:00Z&until=2026-10-01T00:00:00Z"

  setup do
    {:ok, source} =
      Intake.create_input_feed(%{name: "Ars Technica", url: "https://arstechnica.example/feed/"})

    {:ok, _raw} =
      Intake.upsert_raw_item(source, %{
        feed_guid: "ars-1",
        url: "https://arstechnica.example/one/",
        title: "A story about a rocket",
        published_at: ~U[2026-09-30 06:00:00Z],
        discovered_at: ~U[2026-09-30 07:00:00Z]
      })

    {:ok, _run} = Pipeline.process_input_feed(source.id, "test")

    {:ok, feed} =
      Publishing.create_generated_feed(%{"title" => "Tech", "input_feed_ids" => [source.id]})

    {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
    article = Repo.one!(Article)

    Repo.insert!(%ArticleExtraction{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      content_html: "<p>The rocket reached orbit.</p>",
      content_text: "The rocket reached orbit.",
      extracted_at: ~U[2026-09-30 12:00:00Z],
      inserted_at: ~U[2026-09-30 12:00:00Z],
      updated_at: ~U[2026-09-30 12:00:00Z]
    })

    %{article: article, feed: feed}
  end

  test "serves feeds, index, bundle, and a single article as JSON", %{
    conn: conn,
    article: article,
    feed: feed
  } do
    feeds = conn |> get("/internal/api/v1/feeds") |> json_response(200)
    assert [%{"id" => id, "title" => "Tech"}] = feeds["output_feeds"]
    assert id == feed.id
    assert feeds["text"] =~ "Ars Technica"

    index = conn |> get("/internal/api/v1/articles?#{@window}") |> json_response(200)

    assert [%{"guid" => guid, "extraction_state" => "extracted", "feeds" => ["Tech"]}] =
             index["articles"]

    assert guid == article.guid
    assert index["totals"]["readable"] == 1

    bundle =
      conn |> get("/internal/api/v1/bundle?#{@window}&feeds=#{feed.id}") |> json_response(200)

    assert bundle["text"] =~ "The rocket reached orbit."
    assert bundle["text"] =~ "untrusted content"
    # Non-ASCII framing survives JSON encoding intact.
    assert String.valid?(bundle["text"])
    assert bundle["text"] =~ "· feeds: Tech"
    assert bundle["next_cursor"] == nil
    assert bundle["remaining_articles"] == 0

    assert bundle["window"] == %{
             "since" => "2026-09-30T00:00:00Z",
             "until" => "2026-10-01T00:00:00Z"
           }

    one = conn |> get("/internal/api/v1/articles/#{article.guid}") |> json_response(200)
    assert one["text"] =~ "The rocket reached orbit."
    assert one["next_offset"] == nil
  end

  test "maps errors to explicit statuses and codes", %{conn: conn} do
    missing = conn |> get("/internal/api/v1/bundle") |> json_response(400)
    assert missing["error"]["code"] == "invalid_parameter"

    cursor = conn |> get("/internal/api/v1/bundle?cursor=garbage") |> json_response(400)
    assert cursor["error"]["code"] == "invalid_cursor"

    budget = conn |> get("/internal/api/v1/bundle?#{@window}&max_chars=10") |> json_response(400)
    assert budget["error"]["message"] =~ "between 2000 and 320000"

    not_found = conn |> get("/internal/api/v1/articles/art_missing") |> json_response(404)
    assert not_found["error"]["code"] == "not_found"
  end
end
