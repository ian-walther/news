defmodule Newspaper.Publishing.GeneratedFeedInputFeed do
  use Ecto.Schema

  @primary_key false
  schema "generated_feed_input_feeds" do
    belongs_to :generated_feed, Newspaper.Publishing.GeneratedFeed
    belongs_to :input_feed, Newspaper.Intake.InputFeed

    timestamps(type: :utc_datetime)
  end
end
