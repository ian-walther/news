defmodule Newspaper.Processing.PipelineItemStepAttempt do
  @moduledoc """
  Immutable record that an item step was served by an attempt at some point.
  `GeneratedFeedItemStep.latest_attempt_id` is a moving pointer; this is the
  durable participation feed-scoped history reads (audit IMP-16).
  """

  use Ecto.Schema

  schema "pipeline_item_step_attempts" do
    belongs_to :generated_feed_item_step, Newspaper.Processing.GeneratedFeedItemStep
    belongs_to :pipeline_step_attempt, Newspaper.Processing.PipelineStepAttempt
    field :inserted_at, :utc_datetime
  end
end
