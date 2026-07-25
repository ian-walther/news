defmodule Newspaper.IntakeTest do
  use Newspaper.DataCase

  alias Newspaper.Content
  alias Newspaper.Content.Article
  alias Newspaper.Intake
  alias Newspaper.Intake.RawItem
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem

  test "upsert recognizes an existing raw item when either stable ID or URL matches" do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    attrs = %{
      feed_guid: "post-123",
      url: "https://www.theautopian.com/a-real-article/",
      title: "A Real Article",
      discovered_at: ~U[2026-07-24 12:00:00Z]
    }

    assert {:ok, original} = Intake.upsert_raw_item(feed, attrs)

    assert {:ok, same_by_url} =
             Intake.upsert_raw_item(feed, %{attrs | feed_guid: "post-123-reissued"})

    assert {:ok, same_by_guid} =
             Intake.upsert_raw_item(feed, %{
               attrs
               | url: "https://www.theautopian.com/a-real-article/?output=1"
             })

    assert same_by_url.id == original.id
    assert same_by_guid.id == original.id
    assert Repo.aggregate(RawItem, :count) == 1
  end

  test "concurrent intake, dedupe, and publication converge on single rows" do
    {:ok, feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    attrs = %{
      feed_guid: "concurrent-post",
      url: "https://www.theautopian.com/concurrent-post/",
      title: "A Concurrent Article",
      discovered_at: ~U[2026-07-24 12:00:00Z]
    }

    raw_item_ids =
      1..8
      |> Task.async_stream(
        fn _index ->
          {:ok, raw_item} = Intake.upsert_raw_item(feed, attrs, broadcast: false)
          raw_item.id
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert raw_item_ids |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(RawItem, :count) == 1
    raw_item = Repo.get!(RawItem, List.first(raw_item_ids))

    article_ids =
      1..8
      |> Task.async_stream(
        fn _index ->
          Content.create_or_update_from_raw_item(raw_item, [
            "url:https://www.theautopian.com/concurrent-post/",
            "guid:concurrent-post"
          ]).id
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert article_ids |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(Article, :count) == 1
    article = Repo.get!(Article, List.first(article_ids))

    {:ok, output_feed} = Publishing.create_generated_feed(%{"title" => "Cars"})

    item_ids =
      1..8
      |> Task.async_stream(
        fn _index ->
          {:created_or_existing, item} =
            case Publishing.ensure_item_for_feed(output_feed, article) do
              {:created, item} -> {:created_or_existing, item}
              {:existing, item} -> {:created_or_existing, item}
            end

          item.id
        end,
        max_concurrency: 8,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, id} -> id end)

    assert item_ids |> Enum.uniq() |> length() == 1
    assert Repo.aggregate(GeneratedFeedItem, :count) == 1
  end
end
