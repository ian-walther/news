defmodule Newspaper.Repo.Migrations.SeparateSitePacingFromRateLimitBackoff do
  use Ecto.Migration

  def up do
    alter table(:site_extraction_policies) do
      add :minimum_request_interval_ms, :integer, null: false, default: 3000
    end

    execute("""
    UPDATE site_extraction_policies
    SET backoff_until = NULL,
        consecutive_rate_limits = 0
    """)
  end

  def down do
    alter table(:site_extraction_policies) do
      remove :minimum_request_interval_ms
    end
  end
end
