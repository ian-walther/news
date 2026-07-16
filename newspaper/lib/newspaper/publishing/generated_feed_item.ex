defmodule Newspaper.Publishing.GeneratedFeedItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "generated_feed_items" do
    field :guid, :string
    field :rss_guid, :string
    field :published_at, :utc_datetime
    field :item_url, :string
    field :body_mode, :string, default: "original_feed_body"
    field :selection_metadata, :map, default: %{}
    field :rendered_guid, :string
    field :rendered_title, :string
    field :rendered_link_url, :string
    field :rendered_author, :string
    field :rendered_published_at, :utc_datetime
    field :rendered_updated_at, :utc_datetime
    field :rendered_summary, :string
    field :rendered_body, :string
    field :rendered_source_name, :string
    field :rendered_source_url, :string
    field :rendered_categories, {:array, :string}, default: []
    field :rendered_media, :map, default: %{}
    field :rendered_at, :utc_datetime
    field :render_source_metadata, :map, default: %{}
    field :render_status, :string, default: "rendered"
    field :render_error, :string
    field :publication_status, :string, default: "published"
    field :first_eligible_at, :utc_datetime
    field :last_rendered_at, :utc_datetime

    belongs_to :generated_feed, Newspaper.Publishing.GeneratedFeed
    belongs_to :article, Newspaper.Content.Article
    belongs_to :representative_raw_item, Newspaper.Intake.RawItem
    has_many :pipeline_step_attempts, Newspaper.Processing.PipelineStepAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :guid,
      :generated_feed_id,
      :article_id,
      :representative_raw_item_id,
      :rss_guid,
      :published_at,
      :item_url,
      :body_mode,
      :selection_metadata,
      :rendered_guid,
      :rendered_title,
      :rendered_link_url,
      :rendered_author,
      :rendered_published_at,
      :rendered_updated_at,
      :rendered_summary,
      :rendered_body,
      :rendered_source_name,
      :rendered_source_url,
      :rendered_categories,
      :rendered_media,
      :rendered_at,
      :render_source_metadata,
      :render_status,
      :render_error,
      :publication_status,
      :first_eligible_at,
      :last_rendered_at
    ])
    |> Newspaper.Guid.put_new(:guid, "item")
    |> put_rss_guid()
    |> put_rendered_guid()
    |> validate_required([
      :guid,
      :generated_feed_id,
      :article_id,
      :rss_guid,
      :rendered_guid,
      :rendered_at,
      :first_eligible_at,
      :last_rendered_at
    ])
    |> assoc_constraint(:generated_feed)
    |> assoc_constraint(:article)
    |> assoc_constraint(:representative_raw_item)
    |> unique_constraint(:guid)
    |> unique_constraint(:rss_guid)
    |> unique_constraint([:generated_feed_id, :article_id])
  end

  defp put_rss_guid(changeset) do
    guid = get_field(changeset, :guid)

    case get_field(changeset, :rss_guid) do
      nil when is_binary(guid) -> put_change(changeset, :rss_guid, guid)
      "" when is_binary(guid) -> put_change(changeset, :rss_guid, guid)
      _ -> changeset
    end
  end

  defp put_rendered_guid(changeset) do
    guid = get_field(changeset, :rss_guid) || get_field(changeset, :guid)

    case get_field(changeset, :rendered_guid) do
      nil when is_binary(guid) -> put_change(changeset, :rendered_guid, guid)
      "" when is_binary(guid) -> put_change(changeset, :rendered_guid, guid)
      _ -> changeset
    end
  end
end
