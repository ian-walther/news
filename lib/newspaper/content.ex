defmodule Newspaper.Content do
  import Ecto.Query

  alias Newspaper.Content.{Article, ArticleSource}
  alias Newspaper.Intake.RawItem
  alias Newspaper.Repo

  def list_articles(limit \\ 100) do
    Article
    |> order_by([a], desc_nulls_last: a.published_at, desc: a.inserted_at)
    |> limit(^limit)
    |> preload([
      :intake_group,
      :representative_raw_item,
      article_sources: [:input_feed, :raw_item]
    ])
    |> Repo.all()
  end

  def get_article!(id) do
    Article
    |> Repo.get!(id)
    |> Repo.preload([
      :intake_group,
      :representative_raw_item,
      article_sources: [:input_feed, :raw_item]
    ])
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
end
