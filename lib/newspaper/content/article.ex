defmodule Newspaper.Content.Article do
  use Ecto.Schema
  import Ecto.Changeset

  schema "articles" do
    field :guid, :string
    field :canonical_url, :string
    field :resolved_url, :string
    field :title, :string
    field :author, :string
    field :outlet_name, :string
    field :published_at, :utc_datetime
    field :dedupe_scope, :string
    field :dedupe_key, :string
    field :extraction_status, :string, default: "not_requested"
    field :extracted_content, :string
    field :extraction_metadata, :map, default: %{}

    belongs_to :intake_group, Newspaper.Intake.IntakeGroup
    belongs_to :representative_raw_item, Newspaper.Intake.RawItem
    has_many :article_sources, Newspaper.Content.ArticleSource

    timestamps(type: :utc_datetime)
  end

  def changeset(article, attrs) do
    article
    |> cast(attrs, [
      :guid,
      :intake_group_id,
      :representative_raw_item_id,
      :canonical_url,
      :resolved_url,
      :title,
      :author,
      :outlet_name,
      :published_at,
      :dedupe_scope,
      :dedupe_key,
      :extraction_status,
      :extracted_content,
      :extraction_metadata
    ])
    |> Newspaper.Guid.put_new(:guid, "art")
    |> validate_required([:guid, :dedupe_scope, :dedupe_key])
    |> assoc_constraint(:intake_group)
    |> assoc_constraint(:representative_raw_item)
    |> unique_constraint(:guid)
    |> unique_constraint([:dedupe_scope, :dedupe_key])
  end
end
