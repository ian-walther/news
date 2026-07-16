defmodule Newspaper.Content.ArticleExtraction do
  use Ecto.Schema
  import Ecto.Changeset

  schema "article_extractions" do
    field :implementation_key, :string
    field :final_url, :string
    field :title, :string
    field :byline, :string
    field :published_at, :utc_datetime
    field :content_html, :string
    field :content_text, :string
    field :excerpt, :string
    field :site_name, :string
    field :quality, :map, default: %{}
    field :debug_metadata, :map, default: %{}
    field :extracted_at, :utc_datetime

    belongs_to :article, Newspaper.Content.Article
    belongs_to :pipeline_step_attempt, Newspaper.Processing.PipelineStepAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(extraction, attrs) do
    extraction
    |> cast(attrs, [
      :article_id,
      :pipeline_step_attempt_id,
      :implementation_key,
      :final_url,
      :title,
      :byline,
      :published_at,
      :content_html,
      :content_text,
      :excerpt,
      :site_name,
      :quality,
      :debug_metadata,
      :extracted_at
    ])
    |> validate_required([:article_id, :implementation_key, :content_text, :extracted_at])
    |> assoc_constraint(:article)
    |> assoc_constraint(:pipeline_step_attempt)
    |> unique_constraint(:article_id)
  end
end
