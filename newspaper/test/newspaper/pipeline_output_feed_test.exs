defmodule Newspaper.PipelineOutputFeedTest do
  use Newspaper.DataCase

  alias Newspaper.Content
  alias Newspaper.Content.{Article, ArticleDedupeKey, ArticleSource}
  alias Newspaper.Intake
  alias Newspaper.Intake.RawItem
  alias Newspaper.Operations.Failure
  alias Newspaper.Pipeline
  alias Newspaper.Processing.PipelineStep
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

    assert run.summary_counts == %{
             "articles_seen" => 1,
             "item_failures" => 0,
             "raw_items" => 2
           }

    article = Repo.one!(Article) |> Repo.preload(:article_sources)
    assert article.representative_raw_item_id == earlier_raw_item.id
    assert article.dedupe_scope == "group:#{f1_group.id}"
    assert Repo.aggregate(ArticleSource, :count) == 2

    assert Enum.map(article.article_sources, & &1.input_feed_id) |> Enum.sort() == [
             autosport.id,
             racer.id
           ]
  end

  test "dedupes different URLs across grouped feeds by publisher stable ID" do
    {:ok, outlet} = Intake.create_intake_group(%{name: "Example Outlet"})

    {:ok, technology_feed} =
      Intake.create_input_feed(%{
        intake_group_id: outlet.id,
        name: "Example Technology",
        url: "https://example.com/technology.xml"
      })

    {:ok, business_feed} =
      Intake.create_input_feed(%{
        intake_group_id: outlet.id,
        name: "Example Business",
        url: "https://example.com/business.xml"
      })

    stable_id = "tag:example.com,2026:shared-story"

    for {feed, url} <- [
          {technology_feed, "https://example.com/story?ref=technology"},
          {business_feed, "https://example.com/story?ref=business"}
        ] do
      assert {:ok, _raw_item} =
               Intake.upsert_raw_item(feed, %{
                 feed_guid: stable_id,
                 url: url,
                 title: "A story shared by two publisher feeds",
                 published_at: ~U[2026-07-23 12:00:00Z],
                 discovered_at: ~U[2026-07-23 12:01:00Z]
               })
    end

    assert {:ok, run} = Pipeline.process_intake_group(outlet.id, "test")

    assert run.summary_counts == %{
             "articles_seen" => 1,
             "item_failures" => 0,
             "raw_items" => 2
           }

    assert Repo.aggregate(Article, :count) == 1
    assert Repo.aggregate(ArticleDedupeKey, :count) == 3
    assert Repo.aggregate(ArticleSource, :count) == 2
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

  test "updating output settings without membership fields preserves memberships" do
    {:ok, group} = Intake.create_intake_group(%{name: "Technology"})
    {:ok, feed} = Intake.create_input_feed(%{name: "Ars", url: "https://example.com/ars.xml"})

    {:ok, output} =
      Publishing.create_generated_feed(%{
        "title" => "Tech",
        "intake_group_ids" => [group.id],
        "input_feed_ids" => [feed.id]
      })

    assert {:ok, updated} = Publishing.update_generated_feed(output, %{"title" => "Technology"})

    updated = Publishing.get_generated_feed!(updated.id)
    assert Enum.map(updated.intake_groups, & &1.id) == [group.id]
    assert Enum.map(updated.input_feeds, & &1.id) == [feed.id]
  end

  test "rendering dependencies are enforced outside the LiveView" do
    {:ok, output_feed} = Publishing.create_generated_feed(%{"title" => "Cars"})

    assert {:error, changeset} =
             Publishing.update_generated_feed(output_feed, %{
               link_to_hosted_article: true
             })

    assert {"requires article extraction", _metadata} =
             Keyword.fetch!(changeset.errors, :link_to_hosted_article)
  end

  test "group backfill excludes articles seen only through disabled input feeds" do
    {:ok, group} = Intake.create_intake_group(%{name: "Motorsport"})

    {:ok, input_feed} =
      Intake.create_input_feed(%{
        intake_group_id: group.id,
        name: "Racer",
        url: "https://racer.com/feed/"
      })

    assert {:ok, _raw_item} =
             Intake.upsert_raw_item(input_feed, %{
               feed_guid: "disabled-source-article",
               url: "https://racer.com/disabled-source-article/",
               title: "An article from a disabled source",
               discovered_at: ~U[2026-07-24 12:00:00Z]
             })

    assert {:ok, _run} = Pipeline.process_intake_group(group.id, "test")
    assert {:ok, _input_feed} = Intake.update_input_feed(input_feed, %{enabled: false})

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Motorsport",
        "intake_group_ids" => [group.id]
      })

    assert {:ok, run} = Pipeline.backfill_output_feed(output_feed.id, "test")
    assert run.summary_counts["articles_considered"] == 0
    assert Repo.aggregate(GeneratedFeedItem, :count) == 0
  end

  test "records output item creation errors in the processing run" do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "The Autopian",
        url: "https://www.theautopian.com/feed/"
      })

    assert {:ok, _raw_item} =
             Intake.upsert_raw_item(input_feed, %{
               feed_guid: "autopian-invalid-output-enrollment",
               url: "https://www.theautopian.com/invalid-output-enrollment/",
               title: "An article that reaches a corrupt pipeline definition",
               discovered_at: ~U[2026-07-25 12:00:00Z]
             })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Cars",
        "input_feed_ids" => [input_feed.id]
      })

    %PipelineStep{}
    |> Ecto.Changeset.change(%{
      generated_feed_id: output_feed.id,
      step_type: "extraction",
      implementation_key: "",
      position: 0,
      enabled: true,
      config: %{}
    })
    |> Repo.insert!()

    assert {:ok, run} = Pipeline.process_input_feed(input_feed.id, "test")
    assert run.status == "failed"
    assert run.summary_counts["item_failures"] == 1

    failure = Repo.one!(Failure)
    assert failure.failure_type == "generated_feed_item_create_failed"
    assert failure.run_id == run.id
    assert failure.related["generated_feed_id"] == output_feed.id
    assert failure.related["article_id"] == Repo.one!(Article).id
  end

  test "an earlier source appearance does not replace extraction-corrected metadata" do
    {:ok, group} = Intake.create_intake_group(%{name: "The Autopian"})

    {:ok, later_feed} =
      Intake.create_input_feed(%{
        intake_group_id: group.id,
        name: "Autopian Cars",
        url: "https://example.com/autopian-cars.xml"
      })

    {:ok, earlier_feed} =
      Intake.create_input_feed(%{
        intake_group_id: group.id,
        name: "Autopian Features",
        url: "https://example.com/autopian-features.xml"
      })

    stable_id = "autopian-shared-article"

    assert {:ok, _later_raw_item} =
             Intake.upsert_raw_item(later_feed, %{
               feed_guid: stable_id,
               url: "https://www.theautopian.com/raw-feed-url/",
               title: "A Clickbait Feed Title",
               author: "The Autopian Staff",
               published_at: ~U[2026-07-24 13:00:00Z],
               discovered_at: ~U[2026-07-24 13:01:00Z]
             })

    assert {:ok, _run} = Pipeline.process_intake_group(group.id, "test")
    article = Repo.one!(Article)
    assert {:ok, policy} = Content.get_site_extraction_policy_for_url(article.canonical_url)

    assert {:ok, {_, _, _}} =
             Content.record_extraction_success(article, policy, nil, %{
               "implementation" => "extraction.simple_html",
               "final_url" => "https://www.theautopian.com/canonical-article/",
               "title" => "The Extracted Article Title",
               "byline" => "Mercedes Streeter",
               "content_html" => "<p>Complete article content.</p>",
               "content_text" => "Complete article content.",
               "quality" => %{"score" => 1}
             })

    assert {:ok, earlier_raw_item} =
             Intake.upsert_raw_item(earlier_feed, %{
               feed_guid: stable_id,
               url: "https://www.theautopian.com/older-feed-url/",
               title: "An Older Raw Feed Title",
               author: "Unknown",
               published_at: ~U[2026-07-24 12:00:00Z],
               discovered_at: ~U[2026-07-24 12:01:00Z]
             })

    assert {:ok, _run} = Pipeline.process_intake_group(group.id, "test")

    article = Repo.one!(Article)
    assert article.representative_raw_item_id == earlier_raw_item.id
    assert article.title == "The Extracted Article Title"
    assert article.author == "Mercedes Streeter"
    assert article.resolved_url == "https://www.theautopian.com/canonical-article/"
  end

  test "retrying an unsupported failure does not record an attempt that never ran" do
    {:ok, failure} =
      Newspaper.Operations.create_failure(%{
        failure_type: "generated_feed_render_failed",
        message: "Render failed for The Autopian",
        retryable: true,
        related: %{"generated_feed" => "Cars"}
      })

    assert {:error, :unsupported_failure_type} = Pipeline.retry_failure(failure.id, "test_retry")

    failure = Newspaper.Operations.get_failure!(failure.id)
    assert failure.retry_count == 0
    refute failure.last_attempted_at
  end
end
