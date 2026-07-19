defmodule Newspaper.Repo.Migrations.SetDefaultFetchIntervalToFiveMinutes do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE app_settings ALTER COLUMN fetch_interval_minutes SET DEFAULT 5")

    execute(
      "UPDATE app_settings SET fetch_interval_minutes = 5 WHERE fetch_interval_minutes = 60"
    )
  end

  def down do
    execute("ALTER TABLE app_settings ALTER COLUMN fetch_interval_minutes SET DEFAULT 60")

    execute(
      "UPDATE app_settings SET fetch_interval_minutes = 60 WHERE fetch_interval_minutes = 5"
    )
  end
end
