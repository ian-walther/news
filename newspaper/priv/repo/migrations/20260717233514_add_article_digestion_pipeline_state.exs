defmodule Newspaper.Repo.Migrations.AddArticleDigestionPipelineState do
  use Ecto.Migration

  def up do
    alter table(:app_settings) do
      add :ollama_base_url, :text, null: false, default: "http://desktop.home:11434"
      add :ollama_model, :string
    end

    alter table(:generated_feeds) do
      add :title_source, :string, null: false, default: "original"
      add :body_source, :string, null: false, default: "original_feed"
    end

    execute """
    UPDATE generated_feeds
    SET body_source = CASE
      WHEN use_extracted_content_body THEN 'extracted_content'
      ELSE 'original_feed'
    END
    """

    alter table(:generated_feeds) do
      remove :use_extracted_content_body
    end

    execute "UPDATE generated_feed_items SET body_mode = 'original_feed' WHERE body_mode = 'original_feed_body'"

    alter table(:generated_feed_items) do
      modify :body_mode, :string, default: "original_feed"
    end

    execute """
    ALTER TABLE pipeline_step_attempts
      DROP CONSTRAINT pipeline_step_attempts_pipeline_step_id_fkey,
      ALTER COLUMN pipeline_step_id DROP NOT NULL,
      ADD CONSTRAINT pipeline_step_attempts_pipeline_step_id_fkey
        FOREIGN KEY (pipeline_step_id)
        REFERENCES pipeline_steps(id)
        ON DELETE SET NULL
    """

    create table(:article_digests) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :article_extraction_id, references(:article_extractions, on_delete: :nilify_all)

      add :pipeline_step_attempt_id,
          references(:pipeline_step_attempts, on_delete: :nilify_all)

      add :implementation_key, :string, null: false
      add :model, :string, null: false
      add :prompt_version, :string, null: false
      add :schema_version, :string, null: false
      add :input_fingerprint, :string, null: false
      add :generated_title, :text, null: false
      add :generated_summary, :text, null: false
      add :input_metadata, :map, null: false, default: %{}
      add :output_metadata, :map, null: false, default: %{}
      add :generated_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:article_digests, [:article_id, :input_fingerprint])
    create index(:article_digests, [:model])
    create index(:article_digests, [:input_fingerprint])

    create table(:generated_feed_item_steps) do
      add :generated_feed_item_id,
          references(:generated_feed_items, on_delete: :delete_all),
          null: false

      add :pipeline_step_id, references(:pipeline_steps, on_delete: :nilify_all)
      add :step_type, :string, null: false
      add :implementation_key, :string, null: false
      add :position, :integer, null: false
      add :config_snapshot, :map, null: false, default: %{}
      add :definition_fingerprint, :string, null: false
      add :status, :string, null: false, default: "not_requested"
      add :reused_artifact, :boolean, null: false, default: false
      add :error_message, :text
      add :article_extraction_id, references(:article_extractions, on_delete: :nilify_all)
      add :article_digest_id, references(:article_digests, on_delete: :nilify_all)
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:generated_feed_item_steps, [:generated_feed_item_id, :step_type],
             name: :generated_feed_item_steps_item_type_index
           )

    create index(:generated_feed_item_steps, [:pipeline_step_id, :status])
    create index(:generated_feed_item_steps, [:step_type, :status])

    alter table(:pipeline_step_attempts) do
      add :generated_feed_item_step_id,
          references(:generated_feed_item_steps, on_delete: :nilify_all)
    end

    create index(:pipeline_step_attempts, [:generated_feed_item_step_id])

    alter table(:generated_feed_item_steps) do
      add :latest_attempt_id,
          references(:pipeline_step_attempts, on_delete: :nilify_all)
    end

    create index(:generated_feed_item_steps, [:latest_attempt_id])

    execute """
    INSERT INTO generated_feed_item_steps (
      generated_feed_item_id,
      pipeline_step_id,
      step_type,
      implementation_key,
      position,
      config_snapshot,
      definition_fingerprint,
      status,
      reused_artifact,
      article_extraction_id,
      started_at,
      finished_at,
      inserted_at,
      updated_at
    )
    SELECT
      item.id,
      step.id,
      step.step_type,
      step.implementation_key,
      step.position,
      step.config,
      'extraction.site_policy:v1',
      CASE
        WHEN extraction.id IS NOT NULL THEN 'succeeded'
        WHEN article.extraction_status IN ('queued', 'running', 'failed') THEN article.extraction_status
        ELSE 'not_requested'
      END,
      extraction.id IS NOT NULL,
      extraction.id,
      CASE WHEN article.extraction_status = 'running' THEN article.updated_at ELSE NULL END,
      CASE WHEN extraction.id IS NOT NULL THEN extraction.extracted_at ELSE NULL END,
      NOW(),
      NOW()
    FROM generated_feed_items AS item
    JOIN articles AS article ON article.id = item.article_id
    JOIN pipeline_steps AS step
      ON step.generated_feed_id = item.generated_feed_id
      AND step.step_type = 'extraction'
    LEFT JOIN article_extractions AS extraction ON extraction.article_id = article.id
    """

    execute """
    UPDATE pipeline_step_attempts AS attempt
    SET generated_feed_item_step_id = item_step.id
    FROM generated_feed_item_steps AS item_step
    WHERE item_step.generated_feed_item_id = attempt.generated_feed_item_id
      AND item_step.step_type = attempt.step_type
    """

    execute """
    UPDATE generated_feed_item_steps AS item_step
    SET latest_attempt_id = (
          SELECT attempt.id
          FROM pipeline_step_attempts AS attempt
          JOIN generated_feed_items AS item
            ON item.id = item_step.generated_feed_item_id
          WHERE attempt.article_id = item.article_id
            AND attempt.step_type = item_step.step_type
          ORDER BY attempt.inserted_at DESC, attempt.id DESC
          LIMIT 1
        ),
        error_message = (
          SELECT attempt.error_message
          FROM pipeline_step_attempts AS attempt
          JOIN generated_feed_items AS item
            ON item.id = item_step.generated_feed_item_id
          WHERE attempt.article_id = item.article_id
            AND attempt.step_type = item_step.step_type
          ORDER BY attempt.inserted_at DESC, attempt.id DESC
          LIMIT 1
        )
    """
  end

  def down do
    alter table(:generated_feed_item_steps) do
      remove :latest_attempt_id
    end

    alter table(:pipeline_step_attempts) do
      remove :generated_feed_item_step_id
    end

    drop table(:generated_feed_item_steps)
    drop table(:article_digests)

    execute "DELETE FROM pipeline_step_attempts WHERE pipeline_step_id IS NULL"

    execute """
    ALTER TABLE pipeline_step_attempts
      DROP CONSTRAINT pipeline_step_attempts_pipeline_step_id_fkey,
      ALTER COLUMN pipeline_step_id SET NOT NULL,
      ADD CONSTRAINT pipeline_step_attempts_pipeline_step_id_fkey
        FOREIGN KEY (pipeline_step_id)
        REFERENCES pipeline_steps(id)
        ON DELETE CASCADE
    """

    alter table(:generated_feed_items) do
      modify :body_mode, :string, default: "original_feed_body"
    end

    execute "UPDATE generated_feed_items SET body_mode = 'original_feed_body' WHERE body_mode = 'original_feed'"

    alter table(:generated_feeds) do
      add :use_extracted_content_body, :boolean, null: false, default: false
    end

    execute """
    UPDATE generated_feeds
    SET use_extracted_content_body = body_source = 'extracted_content'
    """

    alter table(:generated_feeds) do
      remove :title_source
      remove :body_source
    end

    alter table(:app_settings) do
      remove :ollama_base_url
      remove :ollama_model
    end
  end
end
