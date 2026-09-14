defmodule Newspaper.Repo.Migrations.AddDigestionPauseToAppSettings do
  use Ecto.Migration

  def up do
    alter table(:app_settings) do
      add :digestion_paused, :boolean, null: false, default: false
    end

    execute("""
    UPDATE app_settings
    SET digestion_paused = TRUE
    WHERE ollama_model IS NULL OR BTRIM(ollama_model) = ''
    """)
  end

  def down do
    alter table(:app_settings) do
      remove :digestion_paused
    end
  end
end
