defmodule Newspaper.Repo.Migrations.RemoveInertRunHistorySetting do
  use Ecto.Migration

  def change do
    alter table(:app_settings) do
      remove :run_history_enabled, :boolean, null: false, default: true
    end
  end
end
