defmodule Newspaper.Repo.Migrations.CreatePipelineBatchMembers do
  use Ecto.Migration

  # Durable batch membership, separate from attempt ownership: an attempt can
  # serve several feeds and several batches, so a batch's progress and
  # cancellation are derived from the item steps it requested, not from
  # `pipeline_step_attempts.batch_run_id`.
  def up do
    create table(:pipeline_batch_members) do
      add :batch_run_id, references(:runs, on_delete: :delete_all), null: false

      add :generated_feed_item_step_id,
          references(:generated_feed_item_steps, on_delete: :delete_all),
          null: false

      add :outcome, :string
      add :outcome_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pipeline_batch_members, [:batch_run_id, :generated_feed_item_step_id])
    create index(:pipeline_batch_members, [:generated_feed_item_step_id])
    create index(:pipeline_batch_members, [:batch_run_id, :outcome])

    execute """
    INSERT INTO pipeline_batch_members (
      batch_run_id, generated_feed_item_step_id, outcome, outcome_at, inserted_at, updated_at
    )
    SELECT DISTINCT ON (attempt.batch_run_id, item_step.id)
      attempt.batch_run_id,
      item_step.id,
      CASE WHEN attempt.status IN ('succeeded', 'failed', 'skipped') THEN attempt.status ELSE NULL END,
      CASE WHEN attempt.status IN ('succeeded', 'failed', 'skipped') THEN attempt.finished_at ELSE NULL END,
      NOW(),
      NOW()
    FROM pipeline_step_attempts AS attempt
    JOIN generated_feed_item_steps AS item_step
      ON item_step.id = attempt.generated_feed_item_step_id
      OR item_step.latest_attempt_id = attempt.id
    WHERE attempt.batch_run_id IS NOT NULL
    ORDER BY attempt.batch_run_id, item_step.id, attempt.id DESC
    ON CONFLICT DO NOTHING
    """

    alter table(:failures) do
      add :resolved_at, :utc_datetime
    end

    create index(:failures, [:resolved_at])
  end

  def down do
    alter table(:failures) do
      remove :resolved_at
    end

    drop table(:pipeline_batch_members)
  end
end
