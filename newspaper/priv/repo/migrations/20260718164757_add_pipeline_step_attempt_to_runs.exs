defmodule Newspaper.Repo.Migrations.AddPipelineStepAttemptToRuns do
  use Ecto.Migration

  def up do
    alter table(:runs) do
      add :pipeline_step_attempt_id,
          references(:pipeline_step_attempts, on_delete: :nilify_all)
    end

    create index(:runs, [:pipeline_step_attempt_id])

    execute """
    UPDATE runs AS run
    SET pipeline_step_attempt_id = attempt.id
    FROM pipeline_step_attempts AS attempt
    WHERE run.run_type = 'pipeline_step'
      AND run.related->>'pipeline_step_attempt_id' = attempt.id::text
    """
  end

  def down do
    alter table(:runs) do
      remove :pipeline_step_attempt_id
    end
  end
end
