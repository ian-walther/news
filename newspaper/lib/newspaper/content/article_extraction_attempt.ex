defmodule Newspaper.Content.ArticleExtractionAttempt do
  use Ecto.Schema
  import Ecto.Changeset

  schema "article_extraction_attempts" do
    field :implementation, :string
    field :status, :string
    field :failure_kind, :string
    field :retryable, :boolean, default: false
    field :message, :string
    field :final_url, :string
    field :quality, :map, default: %{}
    field :input_snapshot, :map, default: %{}
    field :output_snapshot, :map, default: %{}
    field :debug_metadata, :map, default: %{}
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :article, Newspaper.Content.Article
    belongs_to :site_extraction_policy, Newspaper.Content.SiteExtractionPolicy
    belongs_to :pipeline_step_attempt, Newspaper.Processing.PipelineStepAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :article_id,
      :site_extraction_policy_id,
      :pipeline_step_attempt_id,
      :implementation,
      :status,
      :failure_kind,
      :retryable,
      :message,
      :final_url,
      :quality,
      :input_snapshot,
      :output_snapshot,
      :debug_metadata,
      :started_at,
      :finished_at
    ])
    |> validate_required([:article_id, :implementation, :status, :started_at, :finished_at])
    |> assoc_constraint(:article)
    |> assoc_constraint(:site_extraction_policy)
    |> assoc_constraint(:pipeline_step_attempt)
  end
end
