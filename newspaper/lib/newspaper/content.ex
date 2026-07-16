defmodule Newspaper.Content do
  import Ecto.Query

  alias Newspaper.Content.{
    Article,
    ArticleExtraction,
    ArticleExtractionAttempt,
    ArticleSource,
    SiteExtractionPolicy
  }

  alias Newspaper.Intake.RawItem
  alias Newspaper.Processing.Registry
  alias Newspaper.Repo

  def list_articles(limit \\ 100) do
    Article
    |> order_by([a], desc_nulls_last: a.published_at, desc: a.inserted_at)
    |> limit(^limit)
    |> preload([
      :intake_group,
      :representative_raw_item,
      :extraction,
      article_sources: [:input_feed, :raw_item]
    ])
    |> Repo.all()
  end

  def article_status_counts do
    counts =
      Article
      |> group_by([article], article.extraction_status)
      |> select([article], {article.extraction_status, count(article.id)})
      |> Repo.all()
      |> Map.new()

    %{
      total: Enum.sum(Map.values(counts)),
      extracted: Map.get(counts, "succeeded", 0),
      failed: Map.get(counts, "failed", 0),
      queued: Map.get(counts, "queued", 0),
      running: Map.get(counts, "running", 0),
      not_requested: Map.get(counts, "not_requested", 0)
    }
  end

  def list_recent_extracted_articles(limit \\ 8) do
    Article
    |> join(:inner, [article], extraction in ArticleExtraction,
      on: extraction.article_id == article.id
    )
    |> order_by([_article, extraction], desc: extraction.extracted_at, desc: extraction.id)
    |> limit(^limit)
    |> preload([_article, extraction], extraction: extraction)
    |> Repo.all()
  end

  def list_active_site_backoffs(now \\ DateTime.utc_now(:second)) do
    SiteExtractionPolicy
    |> where(
      [policy],
      policy.backoff_until > ^now or policy.consecutive_rate_limits > 0
    )
    |> order_by([policy], desc: policy.backoff_until, asc: policy.site_host)
    |> Repo.all()
  end

  def get_article!(id) do
    Article
    |> Repo.get!(id)
    |> Repo.preload([
      :intake_group,
      :representative_raw_item,
      :extraction,
      article_sources: [:input_feed, :raw_item]
    ])
  end

  def get_article_by_guid!(guid) do
    Article
    |> Repo.get_by!(guid: guid)
    |> Repo.preload([:extraction, :article_extraction_attempts, :pipeline_step_attempts])
  end

  def get_article_by_dedupe_key(dedupe_scope, dedupe_key) do
    Repo.one(
      from a in Article,
        where: a.dedupe_scope == ^dedupe_scope and a.dedupe_key == ^dedupe_key,
        limit: 1
    )
  end

  def get_article_by_dedupe_keys(dedupe_scope, dedupe_keys) do
    keys = Enum.reject(dedupe_keys, &is_nil/1)

    Repo.one(
      from a in Article,
        where: a.dedupe_scope == ^dedupe_scope and a.dedupe_key in ^keys,
        order_by: [asc: a.inserted_at],
        limit: 1
    )
  end

  def create_or_update_from_raw_item(%RawItem{} = raw_item, dedupe_keys)
      when is_list(dedupe_keys) do
    dedupe_scope = dedupe_scope(raw_item)
    dedupe_key = Enum.find(dedupe_keys, & &1) || "raw:#{raw_item.id}"
    attrs = article_attrs(raw_item, dedupe_scope, dedupe_key)

    article =
      case get_article_by_dedupe_keys(dedupe_scope, dedupe_keys) do
        nil ->
          %Article{}
          |> Article.changeset(attrs)
          |> Repo.insert!()

        %Article{} = article ->
          maybe_update_representative(article, raw_item)
      end

    create_article_source(article, raw_item)
    article
  end

  def create_or_update_from_raw_item(%RawItem{} = raw_item, dedupe_key) do
    create_or_update_from_raw_item(raw_item, [dedupe_key])
  end

  def change_article(%Article{} = article, attrs \\ %{}), do: Article.changeset(article, attrs)

  def set_extraction_status(%Article{} = article, status) do
    article
    |> Article.changeset(%{extraction_status: status})
    |> Repo.update()
  end

  def get_site_extraction_policy_for_url(url) do
    url
    |> site_host()
    |> get_or_create_site_extraction_policy()
  end

  def get_or_create_site_extraction_policy(nil), do: {:error, :missing_site_host}

  def get_or_create_site_extraction_policy(site_host) do
    site_host = normalize_host(site_host)

    case Repo.get_by(SiteExtractionPolicy, site_host: site_host) do
      nil ->
        %SiteExtractionPolicy{}
        |> SiteExtractionPolicy.changeset(%{site_host: site_host})
        |> Repo.insert(on_conflict: :nothing, conflict_target: :site_host)
        |> case do
          {:ok, %SiteExtractionPolicy{id: nil}} ->
            {:ok, Repo.get_by!(SiteExtractionPolicy, site_host: site_host)}

          result ->
            result
        end

      %SiteExtractionPolicy{} = policy ->
        {:ok, policy}
    end
  end

  def site_host(url) when is_binary(url) do
    url
    |> URI.parse()
    |> Map.get(:host)
    |> normalize_host()
  rescue
    _ -> nil
  end

  def site_host(_url), do: nil

  def backoff_active?(%SiteExtractionPolicy{backoff_until: nil}, _now), do: false

  def backoff_active?(%SiteExtractionPolicy{backoff_until: backoff_until}, now) do
    DateTime.compare(backoff_until, now) == :gt
  end

  def extraction_wait_ms(%SiteExtractionPolicy{} = policy, now \\ DateTime.utc_now()) do
    pacing_wait =
      case policy.last_attempted_at do
        nil ->
          0

        last_attempted_at ->
          max(policy.rate_limit_delay_ms - DateTime.diff(now, last_attempted_at, :millisecond), 0)
      end

    backoff_wait =
      case policy.backoff_until do
        nil -> 0
        backoff_until -> max(DateTime.diff(backoff_until, now, :millisecond), 0)
      end

    max(pacing_wait, backoff_wait)
  end

  def mark_site_extraction_attempted(%SiteExtractionPolicy{} = policy) do
    policy
    |> SiteExtractionPolicy.changeset(%{last_attempted_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  def record_extraction_attempt(attrs) do
    %ArticleExtractionAttempt{}
    |> ArticleExtractionAttempt.changeset(attrs)
    |> Repo.insert()
  end

  def record_extraction_success(
        %Article{} = article,
        %SiteExtractionPolicy{} = policy,
        pipeline_step_attempt_id,
        result
      ) do
    Repo.transaction(fn ->
      extraction_attrs = %{
        article_id: article.id,
        pipeline_step_attempt_id: pipeline_step_attempt_id,
        implementation_key: result["implementation"],
        final_url: result["final_url"],
        title: result["title"],
        byline: result["byline"],
        published_at: result["published_at"],
        content_html: result["content_html"],
        content_text: result["content_text"],
        excerpt: result["excerpt"],
        site_name: result["site_name"],
        quality: result["quality"] || %{},
        debug_metadata: result["debug_metadata"] || %{},
        extracted_at: DateTime.utc_now(:second)
      }

      extraction = Repo.get_by(ArticleExtraction, article_id: article.id) || %ArticleExtraction{}

      extraction
      |> ArticleExtraction.changeset(extraction_attrs)
      |> Repo.insert_or_update!()

      article =
        article
        |> Article.changeset(%{
          resolved_url: result["final_url"] || article.resolved_url,
          title: result["title"] || article.title,
          author: result["byline"] || article.author,
          extraction_status: "succeeded",
          extracted_content: result["content_html"] || result["content_text"],
          extraction_metadata: extraction_metadata(result)
        })
        |> Repo.update!()

      policy =
        policy
        |> SiteExtractionPolicy.changeset(%{
          minimum_implementation:
            learned_minimum_implementation(policy, result["implementation"]),
          last_successful_implementation: result["implementation"],
          last_failure_kind: nil,
          rate_limit_delay_ms: max(div(policy.rate_limit_delay_ms, 2), 3_000),
          consecutive_rate_limits: 0,
          backoff_until: nil
        })
        |> Repo.update!()

      {article, policy}
    end)
  end

  def record_extraction_failure(%Article{} = article, %SiteExtractionPolicy{} = policy, result) do
    Repo.transaction(fn ->
      article =
        article
        |> Article.changeset(%{
          extraction_status: "failed",
          extraction_metadata: extraction_metadata(result)
        })
        |> Repo.update!()

      policy = update_policy_after_failure!(policy, result)

      {article, policy}
    end)
  end

  defp update_policy_after_failure!(
         %SiteExtractionPolicy{} = policy,
         %{"failure_kind" => "rate_limited"} = result
       ) do
    consecutive_rate_limits = policy.consecutive_rate_limits + 1
    retry_after_ms = get_in(result, ["debug_metadata", "retry_after_ms"]) || 0
    delay_ms = max(rate_limit_delay_ms(consecutive_rate_limits), retry_after_ms)
    backoff_until = DateTime.add(DateTime.utc_now(:second), div(delay_ms, 1000), :second)

    policy
    |> SiteExtractionPolicy.changeset(%{
      last_failure_kind: result["failure_kind"],
      rate_limit_delay_ms: delay_ms,
      backoff_until: backoff_until,
      consecutive_rate_limits: consecutive_rate_limits,
      last_rate_limited_at: DateTime.utc_now(:second)
    })
    |> Repo.update!()
  end

  defp update_policy_after_failure!(%SiteExtractionPolicy{} = policy, result) do
    policy
    |> SiteExtractionPolicy.changeset(%{last_failure_kind: result["failure_kind"]})
    |> Repo.update!()
  end

  defp rate_limit_delay_ms(1), do: 5 * 60 * 1000
  defp rate_limit_delay_ms(2), do: 30 * 60 * 1000
  defp rate_limit_delay_ms(_count), do: 2 * 60 * 60 * 1000

  defp learned_minimum_implementation(policy, implementation) do
    if policy.escalation_enabled and
         Registry.harder_than?(implementation, policy.minimum_implementation) do
      implementation
    else
      policy.minimum_implementation
    end
  end

  defp extraction_metadata(result) do
    %{
      "implementation" => result["implementation"],
      "final_url" => result["final_url"],
      "failure_kind" => result["failure_kind"],
      "retryable" => result["retryable"],
      "message" => result["message"],
      "quality" => result["quality"] || %{},
      "debug_metadata" => result["debug_metadata"] || %{},
      "extracted_at" => DateTime.utc_now(:second) |> DateTime.to_iso8601()
    }
  end

  defp article_attrs(raw_item, dedupe_scope, dedupe_key) do
    %{
      intake_group_id: raw_item.intake_group_id,
      dedupe_scope: dedupe_scope,
      representative_raw_item_id: raw_item.id,
      canonical_url: raw_item.url,
      resolved_url: raw_item.url,
      title: raw_item.title,
      author: raw_item.author,
      outlet_name: raw_item.source_name,
      published_at: raw_item.published_at || raw_item.feed_updated_at || raw_item.discovered_at,
      dedupe_key: dedupe_key
    }
  end

  defp maybe_update_representative(%Article{} = article, %RawItem{} = raw_item) do
    article = Repo.preload(article, :representative_raw_item)

    if earlier_representative?(raw_item, article.representative_raw_item) do
      article
      |> Article.changeset(article_attrs(raw_item, article.dedupe_scope, article.dedupe_key))
      |> Repo.update!()
    else
      article
    end
  end

  defp earlier_representative?(_raw_item, nil), do: true

  defp earlier_representative?(candidate, current) do
    compare_timestamp(candidate) < compare_timestamp(current)
  end

  defp compare_timestamp(raw_item) do
    raw_item.published_at || raw_item.feed_updated_at || raw_item.discovered_at ||
      raw_item.inserted_at
  end

  defp create_article_source(article, raw_item) do
    attrs = %{
      article_id: article.id,
      input_feed_id: raw_item.input_feed_id,
      raw_item_id: raw_item.id,
      first_seen_at: raw_item.discovered_at,
      source_categories: raw_item.categories || []
    }

    %ArticleSource{}
    |> ArticleSource.changeset(attrs)
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:article_id, :raw_item_id]
    )
  end

  defp dedupe_scope(%RawItem{intake_group_id: intake_group_id})
       when is_integer(intake_group_id) do
    "group:#{intake_group_id}"
  end

  defp dedupe_scope(%RawItem{input_feed_id: input_feed_id}) do
    "feed:#{input_feed_id}"
  end

  defp normalize_host(nil), do: nil

  defp normalize_host(host) do
    host
    |> String.downcase()
    |> String.trim_leading("www.")
  end
end
