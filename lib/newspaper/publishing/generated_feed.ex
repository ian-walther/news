defmodule Newspaper.Publishing.GeneratedFeed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "generated_feeds" do
    field :guid, :string
    field :title, :string
    field :description, :string
    field :item_limit, :integer, default: 500
    field :enabled, :boolean, default: true
    field :process_items, :boolean, default: false
    field :link_to_hosted_article, :boolean, default: false
    field :use_extracted_content_body, :boolean, default: false
    field :policy_config, :map, default: %{}

    many_to_many :intake_groups, Newspaper.Intake.IntakeGroup,
      join_through: Newspaper.Publishing.GeneratedFeedIntakeGroup,
      on_replace: :delete

    many_to_many :input_feeds, Newspaper.Intake.InputFeed,
      join_through: Newspaper.Publishing.GeneratedFeedInputFeed,
      on_replace: :delete

    has_many :items, Newspaper.Publishing.GeneratedFeedItem

    timestamps(type: :utc_datetime)
  end

  def changeset(feed, attrs) do
    feed
    |> cast(attrs, [
      :guid,
      :title,
      :description,
      :item_limit,
      :enabled,
      :process_items,
      :link_to_hosted_article,
      :use_extracted_content_body,
      :policy_config
    ])
    |> Newspaper.Guid.put_new(:guid, "feed")
    |> validate_required([:guid, :title, :item_limit])
    |> validate_number(:item_limit, greater_than: 0)
    |> unique_constraint(:guid)
  end
end
