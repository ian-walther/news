defmodule Newspaper.Content.ArticleDigest do
  use Ecto.Schema
  import Ecto.Changeset

  schema "article_digests" do
    field :implementation_key, :string
    field :model, :string
    field :prompt_version, :string
    field :schema_version, :string
    field :input_fingerprint, :string
    field :generated_title, :string
    field :generated_summary, :string
    field :input_metadata, :map, default: %{}
    field :output_metadata, :map, default: %{}
    field :generated_at, :utc_datetime

    belongs_to :article, Newspaper.Content.Article
    belongs_to :article_extraction, Newspaper.Content.ArticleExtraction
    belongs_to :pipeline_step_attempt, Newspaper.Processing.PipelineStepAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(digest, attrs) do
    digest
    |> cast(attrs, [
      :article_id,
      :article_extraction_id,
      :pipeline_step_attempt_id,
      :implementation_key,
      :model,
      :prompt_version,
      :schema_version,
      :input_fingerprint,
      :generated_title,
      :generated_summary,
      :input_metadata,
      :output_metadata,
      :generated_at
    ])
    |> validate_required([
      :article_id,
      :implementation_key,
      :model,
      :prompt_version,
      :schema_version,
      :input_fingerprint,
      :generated_title,
      :generated_summary,
      :generated_at
    ])
    |> validate_length(:generated_title, min: 10, max: 300)
    |> validate_length(:generated_summary, min: 100, max: 5_000)
    |> assoc_constraint(:article)
    |> assoc_constraint(:article_extraction)
    |> assoc_constraint(:pipeline_step_attempt)
  end
end
