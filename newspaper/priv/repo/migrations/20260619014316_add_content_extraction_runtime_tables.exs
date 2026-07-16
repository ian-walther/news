defmodule Newspaper.Repo.Migrations.AddContentExtractionRuntimeTables do
  use Ecto.Migration

  def change do
    create table(:site_extraction_policies) do
      add :site_host, :text, null: false
      add :minimum_implementation, :string, null: false, default: "extraction.simple_html"
      add :last_successful_implementation, :string
      add :last_failure_kind, :string
      add :rate_limit_delay_ms, :integer, null: false, default: 3000
      add :backoff_until, :utc_datetime
      add :consecutive_rate_limits, :integer, null: false, default: 0
      add :last_rate_limited_at, :utc_datetime
      add :escalation_enabled, :boolean, null: false, default: true
      add :notes, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:site_extraction_policies, [:site_host])
    create index(:site_extraction_policies, [:backoff_until])

    create table(:article_extraction_attempts) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false

      add :site_extraction_policy_id,
          references(:site_extraction_policies, on_delete: :nilify_all)

      add :implementation, :string, null: false
      add :status, :string, null: false
      add :failure_kind, :string
      add :retryable, :boolean, null: false, default: false
      add :message, :text
      add :final_url, :text
      add :quality, :map, null: false, default: %{}
      add :input_snapshot, :map, null: false, default: %{}
      add :output_snapshot, :map, null: false, default: %{}
      add :debug_metadata, :map, null: false, default: %{}
      add :started_at, :utc_datetime, null: false
      add :finished_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:article_extraction_attempts, [:article_id])
    create index(:article_extraction_attempts, [:site_extraction_policy_id])
    create index(:article_extraction_attempts, [:status])
    create index(:article_extraction_attempts, [:failure_kind])
  end
end
