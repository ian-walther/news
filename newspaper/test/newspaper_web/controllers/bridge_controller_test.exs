defmodule NewspaperWeb.BridgeControllerTest do
  use NewspaperWeb.ConnCase

  import Newspaper.BridgeFixtures, only: [tamper: 2]

  alias Newspaper.Bridge.Cursor
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

    %{article: article, feed: feed, source: source}
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
    assert conn |> get("/internal/api/v1/bundle") |> json_response(200)

    invalid = conn |> get("/internal/api/v1/bundle?since=yesterday") |> json_response(400)
    assert invalid["error"]["code"] == "invalid_parameter"

    cursor = conn |> get("/internal/api/v1/bundle?cursor=garbage") |> json_response(400)
    assert cursor["error"]["code"] == "invalid_cursor"

    budget = conn |> get("/internal/api/v1/bundle?#{@window}&max_chars=10") |> json_response(400)
    assert budget["error"]["message"] =~ "between 2000 and 320000"

    not_found = conn |> get("/internal/api/v1/articles/art_missing") |> json_response(404)
    assert not_found["error"]["code"] == "not_found"
  end

  test "answers tampered and malformed cursors with 400 invalid_cursor, never a 500", %{
    conn: conn
  } do
    index = conn |> get("/internal/api/v1/articles?#{@window}") |> json_response(200)
    assert index["next_cursor"] == nil

    {:ok, bundle} =
      Newspaper.Bridge.bundle(%{
        "since" => "2026-09-30T00:00:00Z",
        "until" => "2026-10-01T00:00:00Z"
      })

    assert bundle.next_cursor == nil

    request = %{
      since: ~U[2026-09-30 00:00:00Z],
      until: ~U[2026-10-01 00:00:00Z],
      feeds: nil,
      size: 2_000
    }

    bundle_cursor =
      Cursor.encode("bundle", request, %{"f" => nil, "t" => 0, "a" => 1, "o" => 0, "p" => 1})

    index_cursor =
      Cursor.encode("index", %{request | size: 150}, %{"t" => "2026-09-30T06:00:00Z", "a" => 1})

    assert conn |> get("/internal/api/v1/bundle?cursor=#{bundle_cursor}") |> json_response(200)
    assert conn |> get("/internal/api/v1/articles?cursor=#{index_cursor}") |> json_response(200)

    rejected = [
      {"bundle", tamper(bundle_cursor, &Map.put(&1, "size", 400_000))},
      {"bundle", tamper(bundle_cursor, &Map.put(&1, "size", 0))},
      {"bundle", tamper(bundle_cursor, &Map.put(&1, "feeds", "not-a-list"))},
      {"bundle", tamper(bundle_cursor, &Map.put(&1, "since", 42))},
      {"articles", tamper(index_cursor, &Map.put(&1, "size", 301))},
      {"articles", tamper(index_cursor, &Map.put(&1, "size", 0))},
      {"articles", tamper(index_cursor, &Map.put(&1, "pos", %{}))},
      {"articles", tamper(index_cursor, &Map.put(&1, "pos", %{"t" => "yesterday", "a" => 0}))}
    ]

    for {path, cursor} <- rejected do
      body = conn |> get("/internal/api/v1/#{path}?cursor=#{cursor}") |> json_response(400)
      assert body["error"]["code"] == "invalid_cursor"
    end
  end

  test "answers a budget too small for an empty window's framing with 422", %{
    conn: conn,
    source: source
  } do
    feeds =
      for number <- 1..12 do
        {:ok, feed} =
          Publishing.create_generated_feed(%{
            "title" => String.duplicate("Tech ", 40) <> "#{number}",
            "input_feed_ids" => [source.id]
          })

        feed.id
      end

    empty =
      "since=2026-09-29T00:00:00Z&until=2026-09-30T00:00:00Z&feeds=#{Enum.join(feeds, ",")}"

    body = conn |> get("/internal/api/v1/bundle?#{empty}&max_chars=2000") |> json_response(422)
    assert body["error"]["code"] == "budget_too_small"

    page = conn |> get("/internal/api/v1/bundle?#{empty}&max_chars=8000") |> json_response(200)
    assert page["chars"] == String.length(page["text"])
    assert page["chars"] <= 8_000
  end
end
