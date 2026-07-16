defmodule Newspaper.Operations.Run do
  use Ecto.Schema
  import Ecto.Changeset

  schema "runs" do
    field :run_type, :string
    field :trigger, :string
    field :status, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime
    field :summary_counts, :map, default: %{}
    field :related, :map, default: %{}
    field :error_summary, :string
    field :debug_metadata, :map, default: %{}

    has_many :failures, Newspaper.Operations.Failure

    has_many :pipeline_step_attempts, Newspaper.Processing.PipelineStepAttempt,
      foreign_key: :batch_run_id

    timestamps(type: :utc_datetime)
  end

  def changeset(run, attrs) do
    run
    |> cast(attrs, [
      :run_type,
      :trigger,
      :status,
      :started_at,
      :finished_at,
      :summary_counts,
      :related,
      :error_summary,
      :debug_metadata
    ])
    |> validate_required([:run_type, :trigger, :status, :started_at])
  end
end
