defmodule Newspaper.Intake.InputFeed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "input_feeds" do
    field :name, :string
    field :url, :string
    field :outlet_name, :string
    field :default_metadata, :map, default: %{}
    field :enabled, :boolean, default: true
    field :last_fetch_status, :string
    field :last_fetched_at, :utc_datetime
    field :etag, :string
    field :last_modified, :string

    belongs_to :intake_group, Newspaper.Intake.IntakeGroup
    has_many :raw_items, Newspaper.Intake.RawItem

    timestamps(type: :utc_datetime)
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :intake_group_id,
      :name,
      :url,
      :outlet_name,
      :enabled
    ])
    |> validate_required([:name, :url])
    |> validate_format(:url, ~r/^https?:\/\//)
    |> assoc_constraint(:intake_group)
    |> unique_constraint(:url)
  end

  def fetch_state_changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :last_fetch_status,
      :last_fetched_at,
      :etag,
      :last_modified
    ])
  end
end
