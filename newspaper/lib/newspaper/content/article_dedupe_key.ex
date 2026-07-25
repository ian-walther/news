defmodule Newspaper.Content.ArticleDedupeKey do
  use Ecto.Schema
  import Ecto.Changeset

  schema "article_dedupe_keys" do
    field :dedupe_scope, :string
    field :dedupe_key, :string

    belongs_to :article, Newspaper.Content.Article

    timestamps(type: :utc_datetime)
  end

  def changeset(dedupe_key, article_id, attrs) do
    dedupe_key
    |> cast(attrs, [:dedupe_scope, :dedupe_key])
    |> put_change(:article_id, article_id)
    |> validate_required([:article_id, :dedupe_scope, :dedupe_key])
    |> assoc_constraint(:article)
    |> unique_constraint([:dedupe_scope, :dedupe_key])
  end
end
