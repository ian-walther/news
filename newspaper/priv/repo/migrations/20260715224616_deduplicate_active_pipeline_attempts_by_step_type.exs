defmodule Newspaper.Repo.Migrations.DeduplicateActivePipelineAttemptsByStepType do
  use Ecto.Migration

  def up do
    alter table(:pipeline_step_attempts) do
      add :step_type, :string
    end

    execute """
    UPDATE pipeline_step_attempts AS attempts
    SET step_type = steps.step_type
    FROM pipeline_steps AS steps
    WHERE attempts.pipeline_step_id = steps.id
    """

    alter table(:pipeline_step_attempts) do
      modify :step_type, :string, null: false
    end

    drop index(:pipeline_step_attempts, [:pipeline_step_id, :article_id],
           name: :pipeline_step_attempts_one_active
         )

    create unique_index(
             :pipeline_step_attempts,
             [:article_id, :step_type],
             where: "status IN ('queued', 'running')",
             name: :pipeline_step_attempts_one_active_per_type
           )
  end

  def down do
    drop index(:pipeline_step_attempts, [:article_id, :step_type],
           name: :pipeline_step_attempts_one_active_per_type
         )

    alter table(:pipeline_step_attempts) do
      remove :step_type
    end

    create unique_index(
             :pipeline_step_attempts,
             [:pipeline_step_id, :article_id],
             where: "status IN ('queued', 'running')",
             name: :pipeline_step_attempts_one_active
           )
  end
end
