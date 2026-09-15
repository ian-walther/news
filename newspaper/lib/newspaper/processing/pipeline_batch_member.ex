defmodule Newspaper.Processing.PipelineBatchMember do
  @moduledoc """
  One item step a batch requested. `outcome` is nil while the member is
  active and becomes the terminal result for *this batch* — a later batch
  re-requesting the same item step gets its own member row.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @outcomes ~w(succeeded failed skipped cancelled)

  schema "pipeline_batch_members" do
    field :outcome, :string
    field :outcome_at, :utc_datetime

    belongs_to :batch_run, Newspaper.Operations.Run
    belongs_to :generated_feed_item_step, Newspaper.Processing.GeneratedFeedItemStep

    timestamps(type: :utc_datetime)
  end

  def outcomes, do: @outcomes

  def changeset(member, attrs) do
    member
    |> cast(attrs, [:batch_run_id, :generated_feed_item_step_id, :outcome, :outcome_at])
    |> validate_required([:batch_run_id, :generated_feed_item_step_id])
    |> validate_inclusion(:outcome, @outcomes)
    |> assoc_constraint(:batch_run)
    |> assoc_constraint(:generated_feed_item_step)
    |> unique_constraint([:batch_run_id, :generated_feed_item_step_id])
  end
end
