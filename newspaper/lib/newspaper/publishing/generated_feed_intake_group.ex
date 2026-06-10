defmodule Newspaper.Publishing.GeneratedFeedIntakeGroup do
  use Ecto.Schema

  @primary_key false
  schema "generated_feed_intake_groups" do
    belongs_to :generated_feed, Newspaper.Publishing.GeneratedFeed
    belongs_to :intake_group, Newspaper.Intake.IntakeGroup

    timestamps(type: :utc_datetime)
  end
end
