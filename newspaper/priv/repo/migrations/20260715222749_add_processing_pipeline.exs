defmodule Newspaper.Repo.Migrations.AddProcessingPipeline do
  use Ecto.Migration

  def change do
    alter table(:site_extraction_policies) do
      add :last_attempted_at, :utc_datetime
    end

    create table(:pipeline_steps) do
      add :generated_feed_id, references(:generated_feeds, on_delete: :delete_all), null: false
      add :step_type, :string, null: false
      add :implementation_key, :string, null: false
      add :position, :integer, null: false, default: 0
      add :enabled, :boolean, null: false, default: true
      add :config, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    create index(:pipeline_steps, [:generated_feed_id, :position])
    create index(:pipeline_steps, [:step_type, :implementation_key])
    create unique_index(:pipeline_steps, [:generated_feed_id, :step_type])

    create table(:pipeline_step_attempts) do
      add :pipeline_step_id, references(:pipeline_steps, on_delete: :delete_all), null: false
      add :article_id, references(:articles, on_delete: :delete_all), null: false

      add :generated_feed_item_id,
          references(:generated_feed_items, on_delete: :nilify_all)

      add :implementation_key, :string, null: false
      add :status, :string, null: false, default: "queued"
      add :failure_kind, :string
      add :retryable, :boolean, null: false, default: false
      add :error_message, :text
      add :input_snapshot, :map, null: false, default: %{}
      add :output_snapshot, :map, null: false, default: %{}
      add :debug_metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:pipeline_step_attempts, [:pipeline_step_id, :status])
    create index(:pipeline_step_attempts, [:article_id, :status])
    create index(:pipeline_step_attempts, [:generated_feed_item_id])

    create unique_index(
             :pipeline_step_attempts,
             [:pipeline_step_id, :article_id],
             where: "status IN ('queued', 'running')",
             name: :pipeline_step_attempts_one_active
           )

    create table(:article_extractions) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false

      add :pipeline_step_attempt_id,
          references(:pipeline_step_attempts, on_delete: :nilify_all)

      add :implementation_key, :string, null: false
      add :final_url, :text
      add :title, :text
      add :byline, :text
      add :published_at, :utc_datetime
      add :content_html, :text
      add :content_text, :text
      add :excerpt, :text
      add :site_name, :text
      add :quality, :map, null: false, default: %{}
      add :debug_metadata, :map, null: false, default: %{}
      add :extracted_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:article_extractions, [:article_id])
    create index(:article_extractions, [:implementation_key])

    alter table(:article_extraction_attempts) do
      add :pipeline_step_attempt_id,
          references(:pipeline_step_attempts, on_delete: :nilify_all)
    end

    create index(:article_extraction_attempts, [:pipeline_step_attempt_id])
  end
end
