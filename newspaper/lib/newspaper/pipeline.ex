defmodule Newspaper.Pipeline do
  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Intake
  alias Newspaper.Intake.{InputFeed, RawItem}
  alias Newspaper.Operations
  alias Newspaper.Publishing
  alias Newspaper.Processing
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

    case Newspaper.Pipeline.FeedClient.get(feed) do
      {:ok, %Req.Response{status: 304} = response} ->
        Intake.mark_input_feed_fetched(feed, "not_modified", cache_validator_attrs(response))

        Operations.finish_run(run, "succeeded", %{
          summary_counts: %{
            "items" => 0,
            "raw_items_persisted" => 0,
            "articles_seen" => 0,
            "item_failures" => 0
          }
        })

      {:ok, response} ->
        process_feed_response(feed, run, response)

      {:error, reason} ->
        fail_feed_fetch(feed, run, reason)
    end
  end

  defp process_feed_response(feed, run, response) do
    with :ok <- ensure_success(response),
         {:ok, parsed_feed} <- Newspaper.Pipeline.FeedParser.parse(response.body) do
      {raw_items, ingestion_errors} = persist_raw_items(feed, parsed_feed.items, run)
      {articles, processing_errors} = process_raw_items(raw_items, run)
      errors = ingestion_errors ++ processing_errors
      status = if errors == [], do: "ok", else: "failed"

      Intake.mark_input_feed_fetched(feed, status, cache_validator_attrs(response))

      {:ok, finished_run} =
        Operations.finish_run(run, run_status(errors), %{
          summary_counts: %{
            "items" => length(parsed_feed.items),
            "raw_items_persisted" => length(raw_items),
            "articles_seen" => unique_article_count(articles),
            "item_failures" => length(errors)
          },
          error_summary: error_summary(errors)
        })

      if errors == [] do
        {:ok, finished_run}
      else
        {:error, {:item_failures, length(errors)}}
      end
    else
      {:error, reason} ->
        fail_feed_fetch(feed, run, reason)
    end
  end

  defp fail_feed_fetch(feed, run, reason) do
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

  defp cache_validator_attrs(response) do
    [
      etag: Req.Response.get_header(response, "etag") |> List.first(),
      last_modified: Req.Response.get_header(response, "last-modified") |> List.first()
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
    |> Map.new()
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

    {articles, errors} = process_raw_items(raw_items, run)

    Operations.finish_run(run, run_status(errors), %{
      summary_counts: %{
        "raw_items" => length(raw_items),
        "articles_seen" => unique_article_count(articles),
        "item_failures" => length(errors)
      },
      error_summary: error_summary(errors)
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

    {articles, errors} = process_raw_items(raw_items, run)

    Operations.finish_run(run, run_status(errors), %{
      summary_counts: %{
        "raw_items" => length(raw_items),
        "articles_seen" => unique_article_count(articles),
        "item_failures" => length(errors)
      },
      error_summary: error_summary(errors)
    })
  end

  def backfill_output_feed(generated_feed_id, trigger \\ "manual") do
    {:ok, run} =
      Operations.start_run("backfill_output_feed", trigger, %{
        "generated_feed_id" => generated_feed_id
      })

    feed = Newspaper.Publishing.get_generated_feed!(generated_feed_id)

    if feed.enabled do
      summary = backfill_eligible_articles(feed)

      Operations.finish_run(run, "succeeded", %{
        summary_counts: %{
          "articles_considered" => summary.articles_considered,
          "items_created" => summary.items_created,
          "items_existing" => summary.items_existing
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
    results = Enum.map(items, &Publishing.rerender_item(&1, broadcast: false))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    status = if errors == [], do: "succeeded", else: "failed"

    result =
      Operations.finish_run(run, status, %{
        summary_counts: %{
          "items_considered" => length(items),
          "items_rendered" => Enum.count(results, &match?({:ok, _}, &1)),
          "items_failed" => length(errors)
        },
        error_summary: if(errors == [], do: nil, else: "#{length(errors)} item(s) failed")
      })

    Newspaper.Events.broadcast_data_changed(:publishing_changed)
    result
  end

  def retry_failure(failure_id, trigger \\ "manual_retry") do
    failure = Operations.get_failure!(failure_id)

    with true <- failure.retryable,
         :ok <- validate_retry_failure(failure),
         {:ok, _failure} <- Operations.increment_failure_retry(failure) do
      retry_failure_type(failure, trigger)
    else
      false -> {:error, :not_retryable}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_success(%Req.Response{status: status}) when status in 200..299, do: :ok
  defp ensure_success(%Req.Response{status: status}), do: {:error, {:http_status, status}}

  defp persist_raw_items(feed, items, run) do
    Enum.reduce(items, {[], []}, fn item, {raw_items, errors} ->
      case Intake.upsert_raw_item(feed, item, broadcast: false) do
        {:ok, raw_item} ->
          {[raw_item | raw_items], errors}

        {:error, reason} ->
          error = %{raw_item: item, reason: reason}

          Operations.create_failure(%{
            failure_type: "raw_item_ingestion_failed",
            message: inspect(reason),
            retryable: false,
            related: %{
              "input_feed_id" => feed.id,
              "feed_guid" => item.feed_guid,
              "url" => item.url
            },
            run_id: run.id
          })

          {raw_items, [error | errors]}
      end
    end)
    |> then(fn {raw_items, errors} -> {Enum.reverse(raw_items), Enum.reverse(errors)} end)
  end

  defp process_raw_items(raw_items, run) do
    Enum.reduce(raw_items, {[], []}, fn raw_item, {articles, errors} ->
      try do
        article = Content.create_or_update_from_raw_item(raw_item, dedupe_keys(raw_item))
        Publishing.publish_article_to_eligible_feeds(article)
        {[article | articles], errors}
      rescue
        exception ->
          error = %{raw_item: raw_item, reason: exception}

          Operations.create_failure(%{
            failure_type: "raw_item_processing_failed",
            message: Exception.message(exception),
            retryable: false,
            related: %{
              "raw_item_id" => raw_item.id,
              "input_feed_id" => raw_item.input_feed_id,
              "url" => raw_item.url
            },
            run_id: run.id
          })

          {articles, [error | errors]}
      end
    end)
    |> then(fn {articles, errors} -> {Enum.reverse(articles), Enum.reverse(errors)} end)
  end

  defp unique_article_count(articles), do: articles |> Enum.uniq_by(& &1.id) |> length()
  defp run_status([]), do: "succeeded"
  defp run_status(_errors), do: "failed"
  defp error_summary([]), do: nil
  defp error_summary(errors), do: "#{length(errors)} item(s) failed"

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

  defp feed_guid_key(%RawItem{feed_guid: guid}), do: "feed_guid:#{guid}"

  defp tracking_param?(key) do
    key = String.downcase(to_string(key))
    key == "fbclid" or key == "gclid" or String.starts_with?(key, "utm_")
  end

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp backfill_eligible_articles(feed, after_id \\ 0, summary \\ nil)

  defp backfill_eligible_articles(feed, after_id, nil) do
    backfill_eligible_articles(feed, after_id, %{
      articles_considered: 0,
      items_created: 0,
      items_existing: 0
    })
  end

  defp backfill_eligible_articles(feed, after_id, summary) do
    articles = Publishing.list_eligible_articles(feed, after_id: after_id, limit: 500)

    summary =
      Enum.reduce(articles, summary, fn article, summary ->
        summary = Map.update!(summary, :articles_considered, &(&1 + 1))

        case Publishing.ensure_item_for_feed(feed, article) do
          {:created, _item} -> Map.update!(summary, :items_created, &(&1 + 1))
          {:existing, _item} -> Map.update!(summary, :items_existing, &(&1 + 1))
          {:error, reason} -> raise "Could not backfill article #{article.id}: #{inspect(reason)}"
        end
      end)

    case List.last(articles) do
      nil -> summary
      article -> backfill_eligible_articles(feed, article.id, summary)
    end
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

  defp retry_failure_type(
         %{failure_type: "pipeline_step_" <> _kind, related: related},
         _trigger
       ) do
    case related["pipeline_step_attempt_id"] do
      attempt_id when is_integer(attempt_id) -> Processing.retry_attempt(attempt_id)
      _ -> {:error, :missing_pipeline_step_attempt}
    end
  end

  defp retry_failure_type(_failure, _trigger), do: {:error, :unsupported_failure_type}

  defp validate_retry_failure(%{
         failure_type: "fetch_input_feed_failed",
         related: related
       }) do
    if Map.get(related || %{}, "input_feed_id"),
      do: :ok,
      else: {:error, :missing_input_feed_id}
  end

  defp validate_retry_failure(%{
         failure_type: "pipeline_step_" <> _kind,
         related: related
       }) do
    if is_integer((related || %{})["pipeline_step_attempt_id"]),
      do: :ok,
      else: {:error, :missing_pipeline_step_attempt}
  end

  defp validate_retry_failure(_failure), do: {:error, :unsupported_failure_type}

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)
end
