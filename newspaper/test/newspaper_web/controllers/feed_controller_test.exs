defmodule NewspaperWeb.FeedControllerTest do
  use NewspaperWeb.ConnCase

  import Ecto.Query

  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Publishing
  alias Newspaper.Repo

  test "published RSS remains well-formed when source content contains XML delimiters", %{
    conn: conn
  } do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "xml-edge-case",
        url: "https://www.theautopian.com/xml-edge-case/",
        title: "Cars & XML <Together>",
        author: "Mercedes Streeter",
        body: "<p>An awkward delimiter: ]]> and an ampersand: &.</p>",
        media: %{
          "enclosures" => [
            %{
              "url" => "https://cdn.example.com/article.jpg",
              "type" => "image/jpeg",
              "length" => "12345"
            }
          ]
        },
        discovered_at: ~U[2026-07-24 12:00:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars & Technology",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")

    conn = get(conn, "/feeds/#{output_feed.guid}.xml")
    body = response(conn, 200)

    assert get_resp_header(conn, "content-type") == ["application/rss+xml; charset=utf-8"]
    assert {:ok, _document} = Saxy.SimpleForm.parse_string(body)
    assert body =~ "Cars &amp; XML &lt;Together&gt;"
    assert body =~ "<dc:creator>Mercedes Streeter</dc:creator>"
    assert body =~ "<enclosure url=\"https://cdn.example.com/article.jpg\""
    assert body =~ "type=\"image/jpeg\""
    refute body =~ "<![CDATA["
  end

  test "published RSS resolves hosted snapshot paths at the HTTP boundary", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "hosted-link",
        url: "https://www.theautopian.com/hosted-link/",
        title: "Hosted link",
        discovered_at: ~U[2026-07-24 12:00:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Hosted Cars",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")

    item = Repo.one!(GeneratedFeedItem)

    item
    |> Ecto.Changeset.change(rendered_link_url: "/articles/art_hosted")
    |> Repo.update!()

    body =
      conn
      |> get("/feeds/#{output_feed.guid}.xml")
      |> response(200)

    assert body =~ "<link>#{NewspaperWeb.Endpoint.url()}/articles/art_hosted</link>"
  end

  test "unknown, disabled, and malformed feed paths return not found", %{conn: conn} do
    assert conn |> get("/feeds/does-not-exist.xml") |> response(404) == "Not found"

    assert conn |> recycle() |> get("/feeds/too/many/segments.xml") |> response(404) ==
             "Not found"

    {:ok, output_feed} = Publishing.create_generated_feed(%{"title" => "Disabled"})
    assert {:ok, _feed} = Publishing.update_generated_feed(output_feed, %{enabled: false})

    assert conn
           |> recycle()
           |> get("/feeds/#{output_feed.guid}.xml")
           |> response(404) == "Not found"
  end

  test "feed windows exclude processing items and honor the configured item limit", %{conn: conn} do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    for {guid, published_at} <- [
          {"oldest", ~U[2026-07-20 12:00:00Z]},
          {"middle", ~U[2026-07-21 12:00:00Z]},
          {"newest", ~U[2026-07-22 12:00:00Z]}
        ] do
      {:ok, _raw_item} =
        Intake.upsert_raw_item(input_feed, %{
          feed_guid: guid,
          url: "https://www.theautopian.com/#{guid}/",
          title: String.capitalize(guid),
          published_at: published_at,
          discovered_at: ~U[2026-07-24 12:00:00Z]
        })
    end

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "One item",
        "item_limit" => 1,
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")

    newest_item =
      GeneratedFeedItem
      |> order_by(desc: :rendered_published_at)
      |> limit(1)
      |> Repo.one!()

    newest_item
    |> Ecto.Changeset.change(publication_status: "processing")
    |> Repo.update!()

    body =
      conn
      |> get("/feeds/#{output_feed.guid}.xml")
      |> response(200)

    assert body =~ "<title>Middle</title>"
    refute body =~ "<title>Newest</title>"
    refute body =~ "<title>Oldest</title>"
  end
end
