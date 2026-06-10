defmodule Newspaper.Content.ArticleSource do
  use Ecto.Schema
  import Ecto.Changeset

  schema "article_sources" do
    field :first_seen_at, :utc_datetime
    field :source_categories, {:array, :string}, default: []

    belongs_to :article, Newspaper.Content.Article
    belongs_to :input_feed, Newspaper.Intake.InputFeed
    belongs_to :raw_item, Newspaper.Intake.RawItem

    timestamps(type: :utc_datetime)
  end

  def changeset(article_source, attrs) do
    article_source
    |> cast(attrs, [:article_id, :input_feed_id, :raw_item_id, :first_seen_at, :source_categories])
    |> validate_required([:article_id, :input_feed_id, :raw_item_id, :first_seen_at])
    |> assoc_constraint(:article)
    |> assoc_constraint(:input_feed)
    |> assoc_constraint(:raw_item)
    |> unique_constraint([:article_id, :raw_item_id])
  end
end
