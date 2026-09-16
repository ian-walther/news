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
      # Set when enrollment has issued this member's request; until then the
      # member is "selected, not yet requested" and no prior item-step state
      # may satisfy it.
      add :enrolled_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create unique_index(:pipeline_batch_members, [:batch_run_id, :generated_feed_item_step_id])
    create index(:pipeline_batch_members, [:generated_feed_item_step_id])
    create index(:pipeline_batch_members, [:batch_run_id, :outcome])

    create table(:pipeline_batch_attempts) do
      add :batch_run_id, references(:runs, on_delete: :delete_all), null: false

      add :pipeline_step_attempt_id, references(:pipeline_step_attempts, on_delete: :delete_all),
        null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:pipeline_batch_attempts, [:batch_run_id, :pipeline_step_attempt_id])
    create index(:pipeline_batch_attempts, [:pipeline_step_attempt_id])

    # Immutable participation: every attempt an item step ever pointed at.
    # `generated_feed_item_steps.latest_attempt_id` moves on with retries;
    # this does not, so feed-scoped history stays complete.
    create table(:pipeline_item_step_attempts) do
      add :generated_feed_item_step_id,
          references(:generated_feed_item_steps, on_delete: :delete_all),
          null: false

      add :pipeline_step_attempt_id, references(:pipeline_step_attempts, on_delete: :delete_all),
        null: false

      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:pipeline_item_step_attempts, [
             :generated_feed_item_step_id,
             :pipeline_step_attempt_id
           ])

    create index(:pipeline_item_step_attempts, [:pipeline_step_attempt_id])

    # Backfill from the pre-membership schema. The statements live in
    # `Newspaper.Processing.MembershipBackfill` so the upgrade is testable.
    for sql <- Newspaper.Processing.MembershipBackfill.member_statements(), do: execute(sql)
    for sql <- Newspaper.Processing.MembershipBackfill.lineage_statements(), do: execute(sql)

    for sql <- Newspaper.Processing.MembershipBackfill.participation_statements(),
        do: execute(sql)

    alter table(:failures) do
      add :resolved_at, :utc_datetime
    end

    create index(:failures, [:resolved_at])

    for sql <- Newspaper.Processing.MembershipBackfill.resolution_statements(), do: execute(sql)
  end

  def down do
    alter table(:failures) do
      remove :resolved_at
    end

    drop table(:pipeline_item_step_attempts)
    drop table(:pipeline_batch_attempts)
    drop table(:pipeline_batch_members)
  end
end
