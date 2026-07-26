defmodule Newspaper.Publishing.GeneratedFeed do
  use Ecto.Schema
  import Ecto.Changeset

  schema "generated_feeds" do
    field :guid, :string
    field :title, :string
    field :description, :string
    field :item_limit, :integer, default: 500
    field :enabled, :boolean, default: true
    field :link_to_hosted_article, :boolean, default: false
    field :show_digest_in_hosted_article, :boolean, default: false
    field :title_source, :string, default: "original"
    field :body_source, :string, default: "original_feed"
    field :policy_config, :map, default: %{}

    many_to_many :intake_groups, Newspaper.Intake.IntakeGroup,
      join_through: Newspaper.Publishing.GeneratedFeedIntakeGroup,
      on_replace: :delete

    many_to_many :input_feeds, Newspaper.Intake.InputFeed,
      join_through: Newspaper.Publishing.GeneratedFeedInputFeed,
      on_replace: :delete

    has_many :items, Newspaper.Publishing.GeneratedFeedItem
    has_many :pipeline_steps, Newspaper.Processing.PipelineStep

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
      :link_to_hosted_article,
      :show_digest_in_hosted_article,
      :title_source,
      :body_source
    ])
    |> Newspaper.Guid.put_new(:guid, "feed")
    |> validate_required([:guid, :title, :item_limit])
    |> validate_number(:item_limit, greater_than: 0)
    |> validate_inclusion(:title_source, ~w(original digest))
    |> validate_inclusion(:body_source, ~w(original_feed extracted_content digest_summary))
    |> unique_constraint(:guid)
  end
end
