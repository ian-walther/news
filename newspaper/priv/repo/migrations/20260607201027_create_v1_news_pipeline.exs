defmodule Newspaper.Repo.Migrations.CreateV1NewsPipeline do
  use Ecto.Migration

  def change do
    create table(:app_settings) do
      add :fetch_interval_minutes, :integer, null: false, default: 60
      add :run_history_enabled, :boolean, null: false, default: true

      timestamps(type: :utc_datetime)
    end

    create table(:intake_groups) do
      add :name, :string, null: false
      add :outlet_name, :string
      add :enabled, :boolean, null: false, default: true
      add :dedupe_config, :map, null: false, default: %{}
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create index(:intake_groups, [:enabled])

    create table(:input_feeds) do
      add :intake_group_id, references(:intake_groups, on_delete: :restrict), null: false
      add :name, :string, null: false
      add :url, :text, null: false
      add :outlet_name, :string
      add :default_metadata, :map, null: false, default: %{}
      add :enabled, :boolean, null: false, default: true
      add :auth_required, :boolean, null: false, default: false
      add :last_fetch_status, :string
      add :last_fetched_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:input_feeds, [:intake_group_id])
    create unique_index(:input_feeds, [:url])
    create index(:input_feeds, [:enabled])

    create table(:raw_items) do
      add :input_feed_id, references(:input_feeds, on_delete: :restrict), null: false
      add :intake_group_id, references(:intake_groups, on_delete: :restrict), null: false
      add :feed_guid, :text
      add :url, :text
      add :title, :text
      add :author, :text
      add :published_at, :utc_datetime
      add :feed_updated_at, :utc_datetime
      add :body, :text
      add :summary, :text
      add :source_url, :text
      add :source_name, :text
      add :categories, {:array, :string}, null: false, default: []
      add :media, :map, null: false, default: %{}
      add :raw_metadata, :map, null: false, default: %{}
      add :discovered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:raw_items, [:input_feed_id])
    create index(:raw_items, [:intake_group_id])
    create unique_index(:raw_items, [:input_feed_id, :feed_guid], where: "feed_guid IS NOT NULL")
    create unique_index(:raw_items, [:input_feed_id, :url], where: "url IS NOT NULL")

    create table(:articles) do
      add :guid, :string, null: false
      add :intake_group_id, references(:intake_groups, on_delete: :restrict), null: false
      add :representative_raw_item_id, references(:raw_items, on_delete: :nilify_all)
      add :canonical_url, :text
      add :resolved_url, :text
      add :title, :text
      add :author, :text
      add :outlet_name, :text
      add :published_at, :utc_datetime
      add :dedupe_key, :text, null: false
      add :extraction_status, :string, null: false, default: "not_requested"
      add :extracted_content, :text
      add :extraction_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:articles, [:guid])
    create unique_index(:articles, [:intake_group_id, :dedupe_key])
    create index(:articles, [:representative_raw_item_id])
    create index(:articles, [:published_at])

    create table(:article_sources) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :input_feed_id, references(:input_feeds, on_delete: :restrict), null: false
      add :raw_item_id, references(:raw_items, on_delete: :restrict), null: false
      add :first_seen_at, :utc_datetime, null: false
      add :source_categories, {:array, :string}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:article_sources, [:article_id, :raw_item_id])
    create index(:article_sources, [:input_feed_id])

    create table(:generated_feeds) do
      add :guid, :string, null: false
      add :title, :string, null: false
      add :description, :text
      add :item_limit, :integer, null: false, default: 500
      add :enabled, :boolean, null: false, default: true
      add :process_items, :boolean, null: false, default: false
      add :link_to_hosted_article, :boolean, null: false, default: false
      add :use_extracted_content_body, :boolean, null: false, default: false
      add :policy_config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create unique_index(:generated_feeds, [:guid])
    create index(:generated_feeds, [:enabled])

    create table(:generated_feed_intake_groups) do
      add :generated_feed_id, references(:generated_feeds, on_delete: :delete_all), null: false
      add :intake_group_id, references(:intake_groups, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:generated_feed_intake_groups, [:generated_feed_id, :intake_group_id],
             name: :generated_feed_intake_groups_unique
           )

    create table(:generated_feed_input_feeds) do
      add :generated_feed_id, references(:generated_feeds, on_delete: :delete_all), null: false
      add :input_feed_id, references(:input_feeds, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:generated_feed_input_feeds, [:generated_feed_id, :input_feed_id],
             name: :generated_feed_input_feeds_unique
           )

    create table(:generated_feed_items) do
      add :guid, :string, null: false
      add :generated_feed_id, references(:generated_feeds, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :restrict), null: false
      add :representative_raw_item_id, references(:raw_items, on_delete: :restrict)
      add :rss_guid, :string, null: false
      add :published_at, :utc_datetime
      add :item_url, :text
      add :body_mode, :string, null: false, default: "original_feed_body"
      add :selection_metadata, :map, null: false, default: %{}
      add :rendered_guid, :string, null: false
      add :rendered_title, :text
      add :rendered_link_url, :text
      add :rendered_author, :text
      add :rendered_published_at, :utc_datetime
      add :rendered_updated_at, :utc_datetime
      add :rendered_summary, :text
      add :rendered_body, :text
      add :rendered_source_name, :text
      add :rendered_source_url, :text
      add :rendered_categories, {:array, :string}, null: false, default: []
      add :rendered_media, :map, null: false, default: %{}
      add :rendered_at, :utc_datetime, null: false
      add :render_source_metadata, :map, null: false, default: %{}
      add :render_status, :string, null: false, default: "rendered"
      add :render_error, :text
      add :publication_status, :string, null: false, default: "published"
      add :first_eligible_at, :utc_datetime, null: false
      add :last_rendered_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:generated_feed_items, [:guid])
    create unique_index(:generated_feed_items, [:rss_guid])
    create unique_index(:generated_feed_items, [:generated_feed_id, :article_id])
    create index(:generated_feed_items, [:generated_feed_id, :rendered_published_at])
    create index(:generated_feed_items, [:publication_status])

    create table(:runs) do
      add :run_type, :string, null: false
      add :trigger, :string, null: false
      add :status, :string, null: false
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime
      add :summary_counts, :map, null: false, default: %{}
      add :related, :map, null: false, default: %{}
      add :error_summary, :text
      add :debug_metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:run_type])
    create index(:runs, [:status])
    create index(:runs, [:started_at])

    create table(:failures) do
      add :failure_type, :string, null: false
      add :message, :text, null: false
      add :retryable, :boolean, null: false, default: false
      add :retry_count, :integer, null: false, default: 0
      add :last_attempted_at, :utc_datetime
      add :related, :map, null: false, default: %{}
      add :run_id, references(:runs, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:failures, [:failure_type])
    create index(:failures, [:retryable])
    create index(:failures, [:inserted_at])
  end
end
