defmodule Newspaper.Processing.PipelineStep do
  use Ecto.Schema
  import Ecto.Changeset

  schema "pipeline_steps" do
    field :step_type, :string
    field :implementation_key, :string
    field :position, :integer, default: 0
    field :enabled, :boolean, default: true
    field :config, :map, default: %{}

    belongs_to :generated_feed, Newspaper.Publishing.GeneratedFeed
    has_many :attempts, Newspaper.Processing.PipelineStepAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(step, attrs) do
    step
    |> cast(attrs, [
      :generated_feed_id,
      :step_type,
      :implementation_key,
      :position,
      :enabled,
      :config
    ])
    |> validate_required([
      :generated_feed_id,
      :step_type,
      :implementation_key,
      :position,
      :config
    ])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> assoc_constraint(:generated_feed)
    |> unique_constraint([:generated_feed_id, :step_type])
  end
end
