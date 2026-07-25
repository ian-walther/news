defmodule Newspaper.Intake.RawItem do
  use Ecto.Schema
  import Ecto.Changeset

  schema "raw_items" do
    field :feed_guid, :string
    field :url, :string
    field :title, :string
    field :author, :string
    field :published_at, :utc_datetime
    field :feed_updated_at, :utc_datetime
    field :body, :string
    field :summary, :string
    field :source_url, :string
    field :source_name, :string
    field :categories, {:array, :string}, default: []
    field :media, :map, default: %{}
    field :raw_metadata, :map, default: %{}
    field :discovered_at, :utc_datetime

    belongs_to :input_feed, Newspaper.Intake.InputFeed
    belongs_to :intake_group, Newspaper.Intake.IntakeGroup
    has_one :article, Newspaper.Content.Article, foreign_key: :representative_raw_item_id

    timestamps(type: :utc_datetime)
  end

  def changeset(raw_item, attrs) do
    raw_item
    |> cast(attrs, [
      :feed_guid,
      :url,
      :title,
      :author,
      :published_at,
      :feed_updated_at,
      :body,
      :summary,
      :source_url,
      :source_name,
      :categories,
      :media,
      :raw_metadata,
      :discovered_at
    ])
    |> validate_required([:input_feed_id, :discovered_at])
    |> assoc_constraint(:input_feed)
    |> assoc_constraint(:intake_group)
    |> unique_constraint(:feed_guid, name: :raw_items_input_feed_id_feed_guid_index)
    |> unique_constraint(:url, name: :raw_items_input_feed_id_url_index)
  end
end
