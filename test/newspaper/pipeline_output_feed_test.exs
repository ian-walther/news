defmodule Newspaper.PipelineOutputFeedTest do
  use Newspaper.DataCase

  alias Newspaper.Content.{Article, ArticleSource}
  alias Newspaper.Intake
  alias Newspaper.Intake.RawItem
  alias Newspaper.Pipeline
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  test "backfills missing output feed items and re-renders snapshots without changing GUIDs" do
    {:ok, autopian} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        outlet_name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    {:ok, raw_item} =
      Intake.upsert_raw_item(autopian, %{
        feed_guid: "https://www.theautopian.com/?p=20260610-miata",
        url: "https://www.theautopian.com/why-the-na-miata-still-works/",
        title: "Why The NA Miata Still Works",
        published_at: ~U[2026-06-10 12:00:00Z],
        body: "<p>The original feed body.</p>",
        summary: "<p>The original feed summary.</p>",
        source_name: "The Autopian",
        source_url: "https://www.theautopian.com/",
        categories: ["Cars"],
        discovered_at: ~U[2026-06-10 12:05:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(autopian.id, "test")

    {:ok, cars_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_freshrss_cars_test",
        "description" => "Seeded from the FreshRSS Cars category.",
        "input_feed_ids" => [autopian.id]
      })

    assert {:ok, run} = Pipeline.backfill_output_feed(cars_feed.id, "test")

    assert run.summary_counts == %{
             "articles_considered" => 1,
             "items_created" => 1,
             "items_existing" => 0
           }

    item = Repo.one!(GeneratedFeedItem)
    original_guid = item.guid
    original_rss_guid = item.rss_guid
    assert item.rendered_title == "Why The NA Miata Still Works"
    assert item.rendered_body == "<p>The original feed body.</p>"

    raw_item
    |> RawItem.changeset(%{
      title: "Why The NA Miata Still Works So Well",
      body: "<p>The corrected feed body.</p>"
    })
    |> Repo.update!()

    assert {:ok, run} = Pipeline.rerender_output_feed(cars_feed.id, "test")

    assert run.summary_counts == %{
             "items_considered" => 1,
             "items_failed" => 0,
             "items_rendered" => 1
           }

    item = Repo.get!(GeneratedFeedItem, item.id)
    assert item.guid == original_guid
    assert item.rss_guid == original_rss_guid
    assert item.rendered_title == "Why The NA Miata Still Works So Well"
    assert item.rendered_body == "<p>The corrected feed body.</p>"
  end

  test "dedupes repeated articles inside an intake group and preserves source appearances" do
    {:ok, f1_group} =
      Intake.create_intake_group(%{
        name: "F1",
        outlet_name: "Formula 1"
      })

    {:ok, autosport} =
      Intake.create_input_feed(%{
        intake_group_id: f1_group.id,
        name: "Formula 1 news - Autosport",
        outlet_name: "Autosport",
        url: "https://www.autosport.com/rss/f1/news/"
      })

    {:ok, racer} =
      Intake.create_input_feed(%{
        intake_group_id: f1_group.id,
        name: "Formula 1 | RACER",
        outlet_name: "RACER",
        url: "https://racer.com/category/f1/feed"
      })

    article_url = "https://www.autosport.com/f1/news/canadian-gp-practice-analysis/"

    {:ok, _later_raw_item} =
      Intake.upsert_raw_item(racer, %{
        feed_guid: "racer-f1-canadian-gp-practice",
        url: article_url,
        title: "Canadian GP practice analysis",
        published_at: ~U[2026-06-10 14:00:00Z],
        body: "<p>RACER body.</p>",
        source_name: "RACER",
        source_url: "https://racer.com/",
        categories: ["F1"],
        discovered_at: ~U[2026-06-10 14:05:00Z]
      })

    {:ok, earlier_raw_item} =
      Intake.upsert_raw_item(autosport, %{
        feed_guid: "autosport-f1-canadian-gp-practice",
        url: article_url <> "?utm_source=rss",
        title: "Canadian GP practice analysis",
        published_at: ~U[2026-06-10 13:00:00Z],
        body: "<p>Autosport body.</p>",
        source_name: "Autosport",
        source_url: "https://www.autosport.com/",
        categories: ["F1"],
        discovered_at: ~U[2026-06-10 13:05:00Z]
      })

    assert {:ok, run} = Pipeline.process_intake_group(f1_group.id, "test")
    assert run.summary_counts == %{"articles_seen" => 1, "raw_items" => 2}

    article = Repo.one!(Article) |> Repo.preload(:article_sources)
    assert article.representative_raw_item_id == earlier_raw_item.id
    assert article.dedupe_scope == "group:#{f1_group.id}"
    assert Repo.aggregate(ArticleSource, :count) == 2

    assert Enum.map(article.article_sources, & &1.input_feed_id) |> Enum.sort() == [
             autosport.id,
             racer.id
           ]
  end

  test "backfill skips disabled output feeds" do
    {:ok, the_drive} =
      Intake.create_input_feed(%{
        name: "The Drive",
        outlet_name: "The Drive",
        url: "https://www.thedrive.com/feed"
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(the_drive, %{
        feed_guid: "https://www.thedrive.com/news/2026-cars",
        url: "https://www.thedrive.com/news/interesting-car-news",
        title: "Interesting Car News",
        published_at: ~U[2026-06-10 15:00:00Z],
        body: "<p>The Drive body.</p>",
        source_name: "The Drive",
        source_url: "https://www.thedrive.com/",
        categories: ["Cars"],
        discovered_at: ~U[2026-06-10 15:05:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(the_drive.id, "test")

    {:ok, cars_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "guid" => "feed_freshrss_cars_disabled_test",
        "enabled" => false,
        "input_feed_ids" => [the_drive.id]
      })

    assert {:ok, run} = Pipeline.backfill_output_feed(cars_feed.id, "test")

    assert run.summary_counts == %{
             "articles_considered" => 0,
             "items_created" => 0,
             "items_existing" => 0,
             "skipped_disabled_feed" => 1
           }

    assert Repo.aggregate(GeneratedFeedItem, :count) == 0
  end

  test "retrying an unsupported retryable failure records the manual attempt" do
    {:ok, failure} =
      Newspaper.Operations.create_failure(%{
        failure_type: "generated_feed_render_failed",
        message: "Render failed for The Autopian",
        retryable: true,
        related: %{"generated_feed" => "Cars"}
      })

    assert {:error, :unsupported_failure_type} = Pipeline.retry_failure(failure.id, "test_retry")

    failure = Newspaper.Operations.get_failure!(failure.id)
    assert failure.retry_count == 1
    assert failure.last_attempted_at
  end
end
