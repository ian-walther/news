defmodule Newspaper.Publishing do
  import Ecto.Query

  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake.{InputFeed, IntakeGroup, RawItem}
  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Processing
  alias Newspaper.Repo

  def list_generated_feeds do
    GeneratedFeed
    |> order_by([f], asc: f.title)
    |> preload([:intake_groups, :input_feeds, :pipeline_steps])
    |> Repo.all()
  end

  def list_enabled_generated_feeds do
    GeneratedFeed
    |> where([f], f.enabled == true)
    |> order_by([f], asc: f.title)
    |> preload([:intake_groups, :input_feeds])
    |> Repo.all()
  end

  def get_generated_feed!(id), do: Repo.get!(GeneratedFeed, id) |> preload_feed()

  def get_generated_feed_by_guid(guid) do
    GeneratedFeed
    |> where([f], f.guid == ^guid and f.enabled == true)
    |> Repo.one()
  end

  def create_generated_feed(attrs) do
    %GeneratedFeed{}
    |> GeneratedFeed.changeset(attrs)
    |> put_memberships(attrs)
    |> Repo.insert()
    |> broadcast_on_ok(:publishing_changed)
  end

  def update_generated_feed(%GeneratedFeed{} = feed, attrs) do
    feed
    |> preload_feed()
    |> GeneratedFeed.changeset(attrs)
    |> put_memberships(attrs)
    |> Repo.update()
    |> broadcast_on_ok(:publishing_changed)
  end

  def delete_generated_feed(%GeneratedFeed{} = feed) do
    feed
    |> Repo.delete()
    |> broadcast_on_ok(:publishing_changed)
  end

  def change_generated_feed(%GeneratedFeed{} = feed, attrs \\ %{}) do
    feed
    |> preload_feed()
    |> GeneratedFeed.changeset(attrs)
  end

  def list_recent_items(arg \\ 100)

  def list_recent_items(%GeneratedFeed{} = feed) do
    limit = feed.item_limit || 500

    GeneratedFeedItem
    |> where([i], i.generated_feed_id == ^feed.id and i.publication_status == "published")
    |> order_by([i],
      desc_nulls_last: i.rendered_published_at,
      desc_nulls_last: i.published_at,
      desc: i.inserted_at
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def list_recent_items(limit) when is_integer(limit) do
    GeneratedFeedItem
    |> order_by([i],
      desc_nulls_last: i.rendered_published_at,
      desc_nulls_last: i.published_at,
      desc: i.inserted_at
    )
    |> limit(^limit)
    |> preload([:generated_feed, :article])
    |> Repo.all()
  end

  def list_items_for_feed(%GeneratedFeed{} = feed) do
    GeneratedFeedItem
    |> where([i], i.generated_feed_id == ^feed.id)
    |> order_by([i],
      desc_nulls_last: i.rendered_published_at,
      desc_nulls_last: i.published_at,
      desc: i.inserted_at
    )
    |> preload([:generated_feed, article: [:representative_raw_item, :extraction]])
    |> Repo.all()
  end

  def list_items_for_article(article_id) when is_integer(article_id) do
    GeneratedFeedItem
    |> where([i], i.article_id == ^article_id)
    |> preload([:generated_feed, article: [:representative_raw_item, :extraction]])
    |> Repo.all()
  end

  def publish_article_to_eligible_feeds(%Article{} = article) do
    article = Repo.preload(article, [:article_sources, :representative_raw_item])
    source_ids = Enum.map(article.article_sources, & &1.input_feed_id)
    feed_ids = eligible_generated_feed_ids(article.intake_group_id, source_ids)

    Enum.map(feed_ids, fn feed_id ->
      feed = Repo.get!(GeneratedFeed, feed_id)
      create_item_if_missing(feed, article)
    end)
  end

  def create_item_if_missing(%GeneratedFeed{} = feed, %Article{} = article) do
    case ensure_item_for_feed(feed, article) do
      {:created, item} -> {:ok, item}
      {:existing, item} -> {:ok, item}
    end
  end

  def ensure_item_for_feed(%GeneratedFeed{} = feed, %Article{} = article) do
    case Repo.get_by(GeneratedFeedItem, generated_feed_id: feed.id, article_id: article.id) do
      nil ->
        {:ok, item} = create_item!(feed, article)
        {:created, item}

      item ->
        {:existing, item}
    end
  end

  def rerender_item(%GeneratedFeedItem{} = item) do
    item = Repo.preload(item, [:generated_feed, article: [:representative_raw_item, :extraction]])

    raw_item =
      item.article.representative_raw_item || Repo.get(RawItem, item.representative_raw_item_id)

    item
    |> GeneratedFeedItem.changeset(render_attrs(item.generated_feed, item.article, raw_item))
    |> Repo.update()
    |> broadcast_on_ok(:publishing_changed)
  end

  def feed_url(%GeneratedFeed{guid: guid}), do: "/feeds/#{guid}.xml"

  defp create_item!(feed, article) do
    article = Repo.preload(article, [:representative_raw_item, :extraction])

    raw_item =
      article.representative_raw_item || Repo.get!(RawItem, article.representative_raw_item_id)

    now = DateTime.utc_now(:second)

    attrs =
      %{
        generated_feed_id: feed.id,
        article_id: article.id,
        representative_raw_item_id: raw_item && raw_item.id,
        publication_status: "published",
        first_eligible_at: now
      }
      |> Map.merge(render_attrs(feed, article, raw_item, now))

    result =
      %GeneratedFeedItem{}
      |> GeneratedFeedItem.changeset(attrs)
      |> Repo.insert()
      |> broadcast_on_ok(:publishing_changed)

    with {:ok, item} <- result,
         {:ok, _attempts} <- Processing.enqueue_item(item) do
      {:ok, item}
    end
  end

  defp render_attrs(feed, article, raw_item, now \\ DateTime.utc_now(:second)) do
    body_mode = body_mode(feed, article)

    %{
      representative_raw_item_id: raw_item && raw_item.id,
      published_at:
        raw_item && (raw_item.published_at || raw_item.feed_updated_at || raw_item.discovered_at),
      item_url: raw_item && raw_item.url,
      body_mode: body_mode,
      selection_metadata: %{"mode" => body_mode},
      rendered_title: raw_item && raw_item.title,
      rendered_link_url: rendered_link_url(feed, article, raw_item),
      rendered_author: raw_item && raw_item.author,
      rendered_published_at: raw_item && (raw_item.published_at || raw_item.discovered_at),
      rendered_updated_at: raw_item && raw_item.feed_updated_at,
      rendered_summary: raw_item && raw_item.summary,
      rendered_body: rendered_body(feed, article, raw_item),
      rendered_source_name: raw_item && raw_item.source_name,
      rendered_source_url: raw_item && raw_item.source_url,
      rendered_categories: (raw_item && raw_item.categories) || [],
      rendered_media: (raw_item && raw_item.media) || %{},
      rendered_at: now,
      render_source_metadata: %{
        "representative_raw_item_id" => raw_item && raw_item.id,
        "article_id" => article && article.id,
        "extraction_status" => article && article.extraction_status
      },
      render_status: "rendered",
      render_error: nil,
      last_rendered_at: now
    }
  end

  defp body_mode(%GeneratedFeed{process_items: true, use_extracted_content_body: true}, article) do
    if extracted_html(article), do: "extracted_content", else: "original_feed_body"
  end

  defp body_mode(_feed, _article), do: "original_feed_body"

  defp rendered_body(
         %GeneratedFeed{process_items: true, use_extracted_content_body: true},
         article,
         raw_item
       ) do
    extracted_html(article) || (raw_item && raw_item.body)
  end

  defp rendered_body(_feed, _article, raw_item), do: raw_item && raw_item.body

  defp rendered_link_url(
         %GeneratedFeed{process_items: true, link_to_hosted_article: true},
         %Article{guid: guid} = article,
         raw_item
       ) do
    if extracted_html(article) do
      NewspaperWeb.Endpoint.url()
      |> URI.merge("/articles/#{guid}")
      |> URI.to_string()
    else
      raw_item && raw_item.url
    end
  end

  defp rendered_link_url(_feed, _article, raw_item), do: raw_item && raw_item.url

  defp extracted_html(%Article{extraction: %ArticleExtraction{content_html: content_html}})
       when is_binary(content_html) and content_html != "" do
    content_html
  end

  defp extracted_html(%Article{
         extraction_status: "succeeded",
         extracted_content: extracted_content
       })
       when is_binary(extracted_content) and extracted_content != "" do
    extracted_content
  end

  defp extracted_html(_article), do: nil

  defp eligible_generated_feed_ids(intake_group_id, source_ids) do
    intake_group_feed_ids =
      if is_nil(intake_group_id) do
        []
      else
        Repo.all(
          from gfig in "generated_feed_intake_groups",
            join: gf in GeneratedFeed,
            on: gf.id == gfig.generated_feed_id,
            where: gf.enabled == true and gfig.intake_group_id == ^intake_group_id,
            select: gfig.generated_feed_id
        )
      end

    input_feed_feed_ids =
      if source_ids == [] do
        []
      else
        Repo.all(
          from gfif in "generated_feed_input_feeds",
            join: gf in GeneratedFeed,
            on: gf.id == gfif.generated_feed_id,
            where: gf.enabled == true and gfif.input_feed_id in ^source_ids,
            select: gfif.generated_feed_id
        )
      end

    Enum.uniq(intake_group_feed_ids ++ input_feed_feed_ids)
  end

  defp preload_feed(feed), do: Repo.preload(feed, [:intake_groups, :input_feeds])

  defp put_memberships(changeset, attrs) do
    intake_group_ids = list_ids(attrs, "intake_group_ids", :intake_group_ids)
    input_feed_ids = list_ids(attrs, "input_feed_ids", :input_feed_ids)

    changeset
    |> Ecto.Changeset.put_assoc(
      :intake_groups,
      Repo.all(from g in IntakeGroup, where: g.id in ^intake_group_ids)
    )
    |> Ecto.Changeset.put_assoc(
      :input_feeds,
      Repo.all(from f in InputFeed, where: f.id in ^input_feed_ids)
    )
  end

  defp list_ids(attrs, string_key, atom_key) do
    attrs
    |> Map.get(string_key, Map.get(attrs, atom_key, []))
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.map(fn
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
    end)
  end

  defp broadcast_on_ok({:ok, value}, event) do
    Newspaper.Events.broadcast_data_changed(event)
    {:ok, value}
  end

  defp broadcast_on_ok(result, _event), do: result
end
