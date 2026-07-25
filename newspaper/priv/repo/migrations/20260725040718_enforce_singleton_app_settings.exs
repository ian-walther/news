defmodule Newspaper.Repo.Migrations.EnforceSingletonAppSettings do
  use Ecto.Migration

  def up do
    execute """
    DELETE FROM app_settings
    WHERE id != (SELECT MIN(id) FROM app_settings)
    """

    execute """
    CREATE UNIQUE INDEX app_settings_singleton_index
    ON app_settings ((true))
    """
  end

  def down do
    execute "DROP INDEX app_settings_singleton_index"
  end
end
