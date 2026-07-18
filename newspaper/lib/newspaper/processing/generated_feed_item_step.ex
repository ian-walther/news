defmodule Newspaper.Processing.GeneratedFeedItemStep do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses ~w(not_requested pending blocked queued running succeeded failed skipped)

  schema "generated_feed_item_steps" do
    field :step_type, :string
    field :implementation_key, :string
    field :position, :integer
    field :config_snapshot, :map, default: %{}
    field :definition_fingerprint, :string
    field :status, :string, default: "not_requested"
    field :reused_artifact, :boolean, default: false
    field :error_message, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    belongs_to :generated_feed_item, Newspaper.Publishing.GeneratedFeedItem
    belongs_to :pipeline_step, Newspaper.Processing.PipelineStep
    belongs_to :latest_attempt, Newspaper.Processing.PipelineStepAttempt
    belongs_to :article_extraction, Newspaper.Content.ArticleExtraction
    belongs_to :article_digest, Newspaper.Content.ArticleDigest

    timestamps(type: :utc_datetime)
  end

  def changeset(item_step, attrs) do
    item_step
    |> cast(attrs, [
      :generated_feed_item_id,
      :pipeline_step_id,
      :latest_attempt_id,
      :article_extraction_id,
      :article_digest_id,
      :step_type,
      :implementation_key,
      :position,
      :config_snapshot,
      :definition_fingerprint,
      :status,
      :reused_artifact,
      :error_message,
      :started_at,
      :finished_at
    ])
    |> validate_required([
      :generated_feed_item_id,
      :step_type,
      :implementation_key,
      :position,
      :definition_fingerprint,
      :status
    ])
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:generated_feed_item)
    |> assoc_constraint(:pipeline_step)
    |> assoc_constraint(:latest_attempt)
    |> assoc_constraint(:article_extraction)
    |> assoc_constraint(:article_digest)
    |> unique_constraint([:generated_feed_item_id, :step_type],
      name: :generated_feed_item_steps_item_type_index
    )
  end
end
