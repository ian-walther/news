defmodule Newspaper.Processing.PipelineBatchAttempt do
  @moduledoc """
  Immutable lineage between a batch and every execution that served one of
  its members, including executions created by another feed's batch or a
  foreground request and merely joined. Members record *what* a batch asked
  for; this records *which attempts* answered, and it survives the item
  step's mutable `latest_attempt_id` moving on to a retry (audit IMP-16).
  """

  use Ecto.Schema

  schema "pipeline_batch_attempts" do
    belongs_to :batch_run, Newspaper.Operations.Run
    belongs_to :pipeline_step_attempt, Newspaper.Processing.PipelineStepAttempt
    field :inserted_at, :utc_datetime
  end
end
