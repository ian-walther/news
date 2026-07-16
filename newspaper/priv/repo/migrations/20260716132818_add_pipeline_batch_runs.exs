defmodule Newspaper.Repo.Migrations.AddPipelineBatchRuns do
  use Ecto.Migration

  def change do
    alter table(:pipeline_step_attempts) do
      add :batch_run_id, references(:runs, on_delete: :nilify_all)
    end

    create index(:pipeline_step_attempts, [:batch_run_id, :status])
  end
end
