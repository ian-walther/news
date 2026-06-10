defmodule Newspaper.Pipeline do
  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Intake
  alias Newspaper.Intake.{InputFeed, RawItem}
  alias Newspaper.Operations
  alias Newspaper.Publishing
  alias Newspaper.Repo

  def fetch_all(trigger \\ "manual") do
    {:ok, run} = Operations.start_run("fetch_all", trigger)
    feeds = Intake.list_enabled_input_feeds()

    results =
      Enum.map(feeds, fn feed ->
        fetch_input_feed(feed, "system")
      end)

    summary = %{
      "feeds" => length(feeds),
      "ok" => Enum.count(results, &match?({:ok, _}, &1)),
      "error" => Enum.count(results, &match?({:error, _}, &1))
    }

    status = if summary["error"] == 0, do: "succeeded", else: "failed"
    Operations.finish_run(run, status, %{summary_counts: summary})
  end

  def fetch_input_feed(%InputFeed{} = feed, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("fetch_input_feed", trigger, %{
        "input_feed_id" => feed.id,
        "url" => feed.url
      })

    with {:ok, response} <- Req.get(feed.url),
         :ok <- ensure_success(response),
         {:ok, parsed_feed} <- Newspaper.Pipeline.FeedParser.parse(response.body) do
      raw_items =
        Enum.map(parsed_feed.items, fn item ->
          {:ok, raw_item} = Intake.upsert_raw_item(feed, item)
          raw_item
        end)

      Intake.mark_input_feed_fetched(feed, "ok")
      process_feed_boundary(feed, "system")

      Operations.finish_run(run, "succeeded", %{
        summary_counts: %{"items" => length(raw_items)}
      })
    else
      {:error, reason} ->
        Intake.mark_input_feed_fetched(feed, "failed")

        Operations.create_failure(%{
          failure_type: "fetch_input_feed_failed",
          message: inspect(reason),
          retryable: true,
          related: %{"input_feed_id" => feed.id, "url" => feed.url},
          run_id: run.id
        })

        Operations.finish_run(run, "failed", %{error_summary: inspect(reason)})
        {:error, reason}
    end
  end

  def process_intake_group(intake_group_id, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("process_intake_group", trigger, %{
        "intake_group_id" => intake_group_id
      })

    raw_items =
      RawItem
      |> where([r], r.intake_group_id == ^intake_group_id)
      |> order_by([r],
        asc_nulls_last: r.published_at,
        asc_nulls_last: r.feed_updated_at,
        asc: r.discovered_at,
        asc: r.id
      )
      |> Repo.all()

    articles =
      Enum.map(raw_items, fn raw_item ->
        keys = dedupe_keys(raw_item)
        article = Content.create_or_update_from_raw_item(raw_item, keys)
        Publishing.publish_article_to_eligible_feeds(article)
        article
      end)

    Operations.finish_run(run, "succeeded", %{
      summary_counts: %{
        "raw_items" => length(raw_items),
        "articles_seen" => length(Enum.uniq_by(articles, & &1.id))
      }
    })
  end

  def process_input_feed(input_feed_id, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("process_input_feed", trigger, %{
        "input_feed_id" => input_feed_id
      })

    raw_items =
      RawItem
      |> where([r], r.input_feed_id == ^input_feed_id)
      |> order_by([r],
        asc_nulls_last: r.published_at,
        asc_nulls_last: r.feed_updated_at,
        asc: r.discovered_at,
        asc: r.id
      )
      |> Repo.all()

    articles =
      Enum.map(raw_items, fn raw_item ->
        keys = dedupe_keys(raw_item)
        article = Content.create_or_update_from_raw_item(raw_item, keys)
        Publishing.publish_article_to_eligible_feeds(article)
        article
      end)

    Operations.finish_run(run, "succeeded", %{
      summary_counts: %{
        "raw_items" => length(raw_items),
        "articles_seen" => length(Enum.uniq_by(articles, & &1.id))
      }
    })
  end

  def publish_output_feed(generated_feed_id, trigger \\ "manual") do
    backfill_output_feed(generated_feed_id, trigger)
  end

  def backfill_output_feed(generated_feed_id, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("backfill_output_feed", trigger, %{
        "generated_feed_id" => generated_feed_id
      })

    feed = Newspaper.Publishing.get_generated_feed!(generated_feed_id)

    if feed.enabled do
      articles =
        Content.list_articles(5_000)
        |> Enum.filter(&eligible_for_feed?(&1, feed))

      results = Enum.map(articles, &Publishing.ensure_item_for_feed(feed, &1))

      Operations.finish_run(run, "succeeded", %{
        summary_counts: %{
          "articles_considered" => length(articles),
          "items_created" => Enum.count(results, &match?({:created, _}, &1)),
          "items_existing" => Enum.count(results, &match?({:existing, _}, &1))
        }
      })
    else
      Operations.finish_run(run, "succeeded", %{
        summary_counts: %{
          "articles_considered" => 0,
          "items_created" => 0,
          "items_existing" => 0,
          "skipped_disabled_feed" => 1
        }
      })
    end
  end

  def rerender_output_feed(generated_feed_id, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("rerender_output_feed", trigger, %{
        "generated_feed_id" => generated_feed_id
      })

    feed = Newspaper.Publishing.get_generated_feed!(generated_feed_id)
    items = Publishing.list_items_for_feed(feed)
    results = Enum.map(items, &Publishing.rerender_item/1)
    errors = Enum.filter(results, &match?({:error, _}, &1))

    status = if errors == [], do: "succeeded", else: "failed"

    Operations.finish_run(run, status, %{
      summary_counts: %{
        "items_considered" => length(items),
        "items_rendered" => Enum.count(results, &match?({:ok, _}, &1)),
        "items_failed" => length(errors)
      },
      error_summary: if(errors == [], do: nil, else: "#{length(errors)} item(s) failed")
    })
  end

  def retry_failure(failure_id, trigger \\ "manual_retry") do
    failure = Operations.get_failure!(failure_id)

    with true <- failure.retryable,
         {:ok, _failure} <- Operations.increment_failure_retry(failure) do
      retry_failure_type(failure, trigger)
    else
      false -> {:error, :not_retryable}
      {:error, _changeset} = error -> error
    end
  end

  defp ensure_success(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp ensure_success(%Req.Response{status: status}), do: {:error, {:http_status, status}}

  defp dedupe_keys(%RawItem{} = raw_item) do
    [
      normalized_url_key(raw_item.url),
      feed_guid_key(raw_item)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp normalized_url_key(nil), do: nil
  defp normalized_url_key(""), do: nil

  defp normalized_url_key(url) do
    uri = URI.parse(url)

    query =
      (uri.query || "")
      |> URI.decode_query()
      |> Enum.reject(fn {key, _value} -> tracking_param?(key) end)
      |> Enum.sort()
      |> URI.encode_query()

    normalized =
      %URI{
        uri
        | scheme: uri.scheme && String.downcase(uri.scheme),
          host: uri.host && String.downcase(uri.host),
          query: empty_to_nil(query),
          fragment: nil
      }
      |> URI.to_string()
      |> String.trim_trailing("/")

    "url:#{normalized}"
  rescue
    _ -> nil
  end

  defp feed_guid_key(%RawItem{feed_guid: nil}), do: nil
  defp feed_guid_key(%RawItem{feed_guid: ""}), do: nil

  defp feed_guid_key(%RawItem{input_feed_id: input_feed_id, feed_guid: guid}),
    do: "feed_guid:#{input_feed_id}:#{guid}"

  defp tracking_param?(key) do
    key = String.downcase(to_string(key))
    key == "fbclid" or key == "gclid" or String.starts_with?(key, "utm_")
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp eligible_for_feed?(article, feed) do
    feed = Repo.preload(feed, [:intake_groups, :input_feeds])
    article = Repo.preload(article, :article_sources)

    intake_group_ids = Enum.map(feed.intake_groups, & &1.id)
    input_feed_ids = Enum.map(feed.input_feeds, & &1.id)
    source_ids = Enum.map(article.article_sources, & &1.input_feed_id)

    article.intake_group_id in intake_group_ids or Enum.any?(source_ids, &(&1 in input_feed_ids))
  end

  defp retry_failure_type(%{failure_type: "fetch_input_feed_failed", related: related}, trigger) do
    case Map.get(related || %{}, "input_feed_id") do
      nil ->
        {:error, :missing_input_feed_id}

      input_feed_id ->
        input_feed_id
        |> to_id()
        |> Intake.get_input_feed!()
        |> fetch_input_feed(trigger)
    end
  end

  defp retry_failure_type(_failure, _trigger), do: {:error, :unsupported_failure_type}

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)

  defp process_feed_boundary(%InputFeed{intake_group_id: nil, id: id}, trigger) do
    process_input_feed(id, trigger)
  end

  defp process_feed_boundary(%InputFeed{intake_group_id: intake_group_id}, trigger) do
    process_intake_group(intake_group_id, trigger)
  end
end
