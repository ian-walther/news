defmodule Newspaper.Repo.Migrations.MoveExtractionConfigurationToSitePolicies do
  use Ecto.Migration

  def change do
    alter table(:site_extraction_policies) do
      add :timeout_ms, :integer, null: false, default: 20_000
      add :minimum_text_length, :integer, null: false, default: 500
    end

    execute(
      """
      UPDATE pipeline_steps
      SET implementation_key = 'extraction.site_policy', config = '{}'::jsonb
      WHERE step_type = 'extraction'
      """,
      """
      UPDATE pipeline_steps
      SET implementation_key = 'extraction.simple_html',
          config = '{"timeout_ms": 20000, "minimum_text_length": 500}'::jsonb
      WHERE step_type = 'extraction'
      """
    )
  end
end
