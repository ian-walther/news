defmodule Newspaper.Pipeline.FeedParserTest do
  use ExUnit.Case, async: true

  alias Newspaper.Pipeline.FeedParser

  test "captures rich RSS 2.0 item data without collapsing to the unified parser shape" do
    assert {:ok, feed} = parse_fixture("rss2-rich.xml")
    assert feed.title == "The Autopian"
    assert feed.link == "https://www.theautopian.com/"
    assert feed.updated_at == ~U[2026-07-23 14:30:00Z]
    assert feed.categories == ["Cars"]

    assert [item] = feed.items
    assert item.feed_guid == "autopian-rich-entry"
    assert item.author == "Mercedes Streeter"
    assert item.published_at == ~U[2026-07-23 14:00:00Z]
    assert item.feed_updated_at == ~U[2026-07-23 14:05:00Z]
    assert item.summary =~ "A short feed summary"
    assert item.body =~ "complete article body"
    assert item.body =~ "survive durable intake"
    assert item.categories == ["Cars", "Design"]

    assert item.media == %{
             "enclosures" => [
               %{
                 "length" => "123456",
                 "type" => "audio/mpeg",
                 "url" => "https://www.theautopian.com/media/story.mp3"
               }
             ]
           }

    assert item.raw_metadata["guid"] == "autopian-rich-entry"
    assert get_in(item.raw_metadata, ["extras", "content_encoded"])
  end

  test "captures rich Atom entry data and prefers content over summary" do
    assert {:ok, feed} = parse_fixture("atom-rich.xml")
    assert feed.title == "The Verge"
    assert feed.link == "https://www.theverge.com/"
    assert feed.updated_at == ~U[2026-07-23 15:30:00Z]
    assert feed.categories == ["Technology"]

    assert [item] = feed.items
    assert item.feed_guid == "tag:theverge.com,2026:rich-entry"
    assert item.url == "https://www.theverge.com/tech/rich-entry"
    assert item.author == "Sean Hollister"
    assert item.published_at == ~U[2026-07-23 15:00:00Z]
    assert item.feed_updated_at == ~U[2026-07-23 15:05:00Z]
    assert item.summary =~ "concise Atom summary"
    assert item.body =~ "complete Atom article body"
    assert item.categories == ["Technology", "AI"]

    assert item.media == %{
             "enclosures" => [
               %{
                 "length" => "654321",
                 "type" => "image/jpeg",
                 "url" => "https://cdn.vox-cdn.com/rich-entry.jpg"
               }
             ]
           }

    assert get_in(item.raw_metadata, ["content", "content"]) =~ "complete Atom article body"
  end

  test "keeps malformed item dates as nil without rejecting the feed" do
    xml =
      fixture_path("rss2-rich.xml")
      |> File.read!()
      |> String.replace(
        "Thu, 23 Jul 2026 14:00:00 GMT",
        "definitely not a publication date"
      )

    assert {:ok, %{items: [item]}} = FeedParser.parse(xml)
    assert item.published_at == nil
  end

  defp parse_fixture(name) do
    name
    |> fixture_path()
    |> File.read!()
    |> FeedParser.parse()
  end

  defp fixture_path(name) do
    Path.expand("../fixtures/feeds/#{name}", __DIR__)
  end
end
