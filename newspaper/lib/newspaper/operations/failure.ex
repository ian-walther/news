defmodule Newspaper.Operations.Failure do
  use Ecto.Schema
  import Ecto.Changeset

  schema "failures" do
    field :failure_type, :string
    field :message, :string
    field :retryable, :boolean, default: false
    field :retry_count, :integer, default: 0
    field :last_attempted_at, :utc_datetime
    field :related, :map, default: %{}

    belongs_to :run, Newspaper.Operations.Run

    timestamps(type: :utc_datetime)
  end

  def changeset(failure, attrs) do
    failure
    |> cast(attrs, [
      :failure_type,
      :message,
      :retryable,
      :retry_count,
      :last_attempted_at,
      :related,
      :run_id
    ])
    |> validate_required([:failure_type, :message])
    |> assoc_constraint(:run)
  end
end
