defmodule Newspaper.Publishing do
  import Ecto.Query

  alias Ecto.Changeset
  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction, ArticleSource}
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

  def get_generated_feed(id) do
    case Repo.get(GeneratedFeed, id) do
      nil -> nil
      feed -> preload_feed(feed)
    end
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
    feed = preload_feed(feed)

    feed
    |> GeneratedFeed.changeset(attrs)
    |> validate_rendering_dependencies(feed.pipeline_steps)
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
    feed = preload_feed(feed)

    feed
    |> GeneratedFeed.changeset(attrs)
    |> validate_rendering_dependencies(feed.pipeline_steps)
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
    |> preload([
      :generated_feed,
      pipeline_item_steps: :article_digest,
      article: [:representative_raw_item, :extraction]
    ])
    |> Repo.all()
  end

  def count_items_for_feed(%GeneratedFeed{id: feed_id}), do: count_items_for_feed(feed_id)

  def count_items_for_feed(feed_id) when is_integer(feed_id) do
    Repo.aggregate(
      from(item in GeneratedFeedItem, where: item.generated_feed_id == ^feed_id),
      :count,
      :id
    )
  end

  def list_items_for_article(article_id) when is_integer(article_id) do
    GeneratedFeedItem
    |> where([i], i.article_id == ^article_id)
    |> preload([
      :generated_feed,
      pipeline_item_steps: :article_digest,
      article: [:representative_raw_item, :extraction]
    ])
    |> Repo.all()
  end

  def list_eligible_articles(%GeneratedFeed{} = feed, opts \\ []) do
    feed = preload_feed(feed)
    after_id = Keyword.get(opts, :after_id, 0)
    limit = Keyword.get(opts, :limit, 500)
    direct_feed_ids = Enum.map(feed.input_feeds, & &1.id)
    intake_group_ids = Enum.map(feed.intake_groups, & &1.id)

    Article
    |> join(:inner, [article], source in ArticleSource, on: source.article_id == article.id)
    |> join(:inner, [_article, source], input_feed in InputFeed,
      on: input_feed.id == source.input_feed_id
    )
    |> where(
      [article, _source, input_feed],
      article.id > ^after_id and
        (input_feed.id in ^direct_feed_ids or
           (input_feed.enabled == true and input_feed.intake_group_id in ^intake_group_ids))
    )
    |> distinct([article], article.id)
    |> order_by([article], asc: article.id)
    |> limit(^limit)
    |> Repo.all()
  end

  def publish_article_to_eligible_feeds(%Article{} = article) do
    article = Repo.preload(article, [:article_sources, :representative_raw_item])
    source_ids = Enum.map(article.article_sources, & &1.input_feed_id)
    feed_ids = eligible_generated_feed_ids(source_ids)

    GeneratedFeed
    |> where([feed], feed.id in ^feed_ids)
    |> Repo.all()
    |> Enum.map(fn feed -> {feed, create_item_if_missing(feed, article)} end)
  end

  def create_item_if_missing(%GeneratedFeed{} = feed, %Article{} = article) do
    case ensure_item_for_feed(feed, article) do
      {:created, item} -> {:ok, item}
      {:existing, item} -> {:ok, item}
      {:error, _reason} = error -> error
    end
  end

  def ensure_item_for_feed(%GeneratedFeed{} = feed, %Article{} = article) do
    case Repo.get_by(GeneratedFeedItem, generated_feed_id: feed.id, article_id: article.id) do
      nil ->
        create_item(feed, article)

      item ->
        {:existing, item}
    end
  end

  def rerender_item(%GeneratedFeedItem{} = item, opts \\ []) do
    item =
      Repo.preload(item, [
        :generated_feed,
        pipeline_item_steps: :article_digest,
        article: [:representative_raw_item, :extraction]
      ])

    raw_item =
      item.article.representative_raw_item || Repo.get(RawItem, item.representative_raw_item_id)

    result =
      item
      |> GeneratedFeedItem.changeset(
        render_attrs(item.generated_feed, item.article, raw_item, selected_digest(item))
      )
      |> Repo.update()

    if Keyword.get(opts, :broadcast, true) do
      broadcast_on_ok(result, :publishing_changed)
    else
      result
    end
  end

  def feed_url(%GeneratedFeed{guid: guid}), do: "/feeds/#{guid}.xml"

  defp create_item(feed, article) do
    article = Repo.preload(article, [:representative_raw_item, :extraction])

    raw_item =
      article.representative_raw_item || Repo.get!(RawItem, article.representative_raw_item_id)

    now = DateTime.utc_now(:second)

    attrs =
      %{
        generated_feed_id: feed.id,
        article_id: article.id,
        representative_raw_item_id: raw_item && raw_item.id,
        publication_status: publication_status(feed, nil),
        first_eligible_at: now
      }
      |> Map.merge(render_attrs(feed, article, raw_item, nil, now))

    insert_result =
      %GeneratedFeedItem{}
      |> GeneratedFeedItem.changeset(attrs)
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:generated_feed_id, :article_id]
      )

    case insert_result do
      {:ok, %GeneratedFeedItem{id: nil}} ->
        {:existing,
         Repo.get_by!(GeneratedFeedItem,
           generated_feed_id: feed.id,
           article_id: article.id
         )}

      {:ok, item} ->
        with {:ok, _attempts} <- Processing.enqueue_item(item),
             {:ok, item} <- maybe_rerender_new_item(item, feed) do
          Newspaper.Events.broadcast_data_changed(:publishing_changed)
          {:created, item}
        end

      {:error, _changeset} = error ->
        error
    end
  end

  defp maybe_rerender_new_item(item, feed) do
    if feed.title_source == "digest" or feed.body_source == "digest_summary" do
      rerender_item(item, broadcast: false)
    else
      {:ok, item}
    end
  end

  defp render_attrs(feed, article, raw_item, digest, now \\ DateTime.utc_now(:second)) do
    body_mode = body_mode(feed, article, digest)

    %{
      representative_raw_item_id: raw_item && raw_item.id,
      published_at:
        raw_item && (raw_item.published_at || raw_item.feed_updated_at || raw_item.discovered_at),
      item_url: raw_item && raw_item.url,
      body_mode: body_mode,
      selection_metadata: %{"mode" => body_mode},
      rendered_title: rendered_title(feed, raw_item, digest),
      rendered_link_url: rendered_link_url(feed, article, raw_item),
      rendered_author: raw_item && raw_item.author,
      rendered_published_at: raw_item && (raw_item.published_at || raw_item.discovered_at),
      rendered_updated_at: raw_item && raw_item.feed_updated_at,
      rendered_summary: rendered_summary(feed, raw_item, digest),
      rendered_body: rendered_body(feed, article, raw_item, digest),
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
      publication_status: publication_status(feed, digest),
      last_rendered_at: now
    }
  end

  defp body_mode(%GeneratedFeed{body_source: "digest_summary"}, _article, %ArticleDigest{}),
    do: "digest_summary"

  defp body_mode(%GeneratedFeed{body_source: "extracted_content"}, article, _digest) do
    if extracted_html(article), do: "extracted_content", else: "original_feed"
  end

  defp body_mode(_feed, _article, _digest), do: "original_feed"

  defp rendered_body(
         %GeneratedFeed{body_source: "digest_summary"},
         _article,
         _raw_item,
         %ArticleDigest{generated_summary: summary}
       ) do
    summary_html(summary)
  end

  defp rendered_body(
         %GeneratedFeed{body_source: "extracted_content"},
         article,
         raw_item,
         _digest
       ) do
    extracted_html(article) || (raw_item && raw_item.body)
  end

  defp rendered_body(_feed, _article, raw_item, _digest), do: raw_item && raw_item.body

  defp rendered_title(
         %GeneratedFeed{title_source: "digest"},
         _raw_item,
         %ArticleDigest{generated_title: title}
       ),
       do: title

  defp rendered_title(_feed, raw_item, _digest), do: raw_item && raw_item.title

  defp rendered_summary(
         %GeneratedFeed{body_source: "digest_summary"},
         _raw_item,
         %ArticleDigest{generated_summary: summary}
       ),
       do: summary

  defp rendered_summary(_feed, raw_item, _digest), do: raw_item && raw_item.summary

  defp publication_status(%GeneratedFeed{title_source: "digest"}, nil),
    do: "processing"

  defp publication_status(%GeneratedFeed{body_source: "digest_summary"}, nil),
    do: "processing"

  defp publication_status(_feed, _digest), do: "published"

  defp selected_digest(item) do
    item.pipeline_item_steps
    |> Enum.find(&(&1.step_type == "digestion" and &1.status == "succeeded"))
    |> case do
      nil -> nil
      item_step -> item_step.article_digest
    end
  end

  defp summary_html(summary) when is_binary(summary) do
    summary
    |> String.split(~r/\n\s*\n/, trim: true)
    |> Enum.map_join(fn paragraph ->
      escaped =
        paragraph |> String.trim() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

      "<p>#{escaped}</p>"
    end)
  end

  defp summary_html(_summary), do: nil

  defp rendered_link_url(
         %GeneratedFeed{link_to_hosted_article: true, guid: feed_guid},
         %Article{guid: guid} = article,
         raw_item
       ) do
    if extracted_html(article) do
      "/articles/#{guid}?#{URI.encode_query(%{"feed" => feed_guid})}"
    else
      raw_item && raw_item.url
    end
  end

  defp rendered_link_url(_feed, _article, raw_item), do: raw_item && raw_item.url

  defp extracted_html(%Article{extraction: %ArticleExtraction{content_html: content_html}})
       when is_binary(content_html) and content_html != "" do
    content_html
  end

  defp extracted_html(_article), do: nil

  defp eligible_generated_feed_ids(source_ids) do
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

    intake_group_feed_ids =
      if source_ids == [] do
        []
      else
        Repo.all(
          from gfig in "generated_feed_intake_groups",
            join: gf in GeneratedFeed,
            on: gf.id == gfig.generated_feed_id,
            join: input_feed in InputFeed,
            on: input_feed.intake_group_id == gfig.intake_group_id,
            where:
              gf.enabled == true and input_feed.enabled == true and
                input_feed.id in ^source_ids,
            select: gfig.generated_feed_id
        )
      end

    Enum.uniq(input_feed_feed_ids ++ intake_group_feed_ids)
  end

  defp preload_feed(feed), do: Repo.preload(feed, [:intake_groups, :input_feeds, :pipeline_steps])

  defp validate_rendering_dependencies(changeset, steps) do
    title_source = Changeset.get_field(changeset, :title_source)
    body_source = Changeset.get_field(changeset, :body_source)
    hosted_links = Changeset.get_field(changeset, :link_to_hosted_article)
    extraction_enabled? = enabled_step?(steps, "extraction")
    digestion_enabled? = enabled_step?(steps, "digestion")

    changeset =
      if (title_source == "digest" or body_source == "digest_summary") and
           not digestion_enabled? do
        field = if title_source == "digest", do: :title_source, else: :body_source
        Changeset.add_error(changeset, field, "requires article digestion")
      else
        changeset
      end

    if (hosted_links or body_source == "extracted_content" or title_source == "digest" or
          body_source == "digest_summary") and not extraction_enabled? do
      field =
        cond do
          hosted_links -> :link_to_hosted_article
          title_source == "digest" -> :title_source
          true -> :body_source
        end

      Changeset.add_error(changeset, field, "requires article extraction")
    else
      changeset
    end
  end

  defp enabled_step?(steps, step_type) do
    Enum.any?(steps, &(&1.step_type == step_type and &1.enabled))
  end

  defp put_memberships(changeset, attrs) do
    changeset
    |> maybe_put_membership(
      attrs,
      :intake_groups,
      "intake_group_ids",
      :intake_group_ids,
      IntakeGroup
    )
    |> maybe_put_membership(
      attrs,
      :input_feeds,
      "input_feed_ids",
      :input_feed_ids,
      InputFeed
    )
  end

  defp maybe_put_membership(changeset, attrs, association, string_key, atom_key, schema) do
    if Map.has_key?(attrs, string_key) or Map.has_key?(attrs, atom_key) do
      ids = list_ids(Map.get(attrs, string_key, Map.get(attrs, atom_key)))
      records = Repo.all(from record in schema, where: record.id in ^ids)
      Ecto.Changeset.put_assoc(changeset, association, records)
    else
      changeset
    end
  end

  defp list_ids(value) do
    value
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
