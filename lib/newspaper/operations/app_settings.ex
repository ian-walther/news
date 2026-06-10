defmodule Newspaper.Operations.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_settings" do
    field :fetch_interval_minutes, :integer, default: 60
    field :run_history_enabled, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [:fetch_interval_minutes, :run_history_enabled])
    |> validate_required([:fetch_interval_minutes, :run_history_enabled])
    |> validate_number(:fetch_interval_minutes, greater_than: 0)
  end
end
