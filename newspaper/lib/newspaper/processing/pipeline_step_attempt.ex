defmodule Newspaper.Processing.PipelineStepAttempt do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(queued running succeeded failed)

  schema "pipeline_step_attempts" do
    field :implementation_key, :string
    field :step_type, :string
    field :status, :string, default: "queued"
    field :failure_kind, :string
    field :retryable, :boolean, default: false
    field :error_message, :string
    field :input_snapshot, :map, default: %{}
    field :output_snapshot, :map, default: %{}
    field :debug_metadata, :map, default: %{}
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :pipeline_step, Newspaper.Processing.PipelineStep
    belongs_to :article, Newspaper.Content.Article
    belongs_to :generated_feed_item, Newspaper.Publishing.GeneratedFeedItem
    belongs_to :batch_run, Newspaper.Operations.Run
    has_many :extraction_attempts, Newspaper.Content.ArticleExtractionAttempt
    has_one :article_extraction, Newspaper.Content.ArticleExtraction

    timestamps(type: :utc_datetime)
  end

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, [
      :pipeline_step_id,
      :article_id,
      :generated_feed_item_id,
      :implementation_key,
      :step_type,
      :status,
      :failure_kind,
      :retryable,
      :error_message,
      :input_snapshot,
      :output_snapshot,
      :debug_metadata,
      :started_at,
      :finished_at
    ])
    |> validate_required([
      :pipeline_step_id,
      :article_id,
      :implementation_key,
      :step_type,
      :status,
      :input_snapshot,
      :output_snapshot,
      :debug_metadata
    ])
    |> validate_inclusion(:status, @statuses)
    |> assoc_constraint(:pipeline_step)
    |> assoc_constraint(:article)
    |> assoc_constraint(:generated_feed_item)
    |> unique_constraint([:article_id, :step_type],
      name: :pipeline_step_attempts_one_active_per_type
    )
  end
end
