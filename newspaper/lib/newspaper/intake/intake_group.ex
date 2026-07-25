defmodule Newspaper.Intake.IntakeGroup do
  use Ecto.Schema
  import Ecto.Changeset

  schema "intake_groups" do
    field :name, :string
    field :outlet_name, :string
    field :enabled, :boolean, default: true
    field :dedupe_config, :map, default: %{}
    field :notes, :string

    has_many :input_feeds, Newspaper.Intake.InputFeed

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [:name, :outlet_name, :enabled, :notes])
    |> validate_required([:name])
  end
end
