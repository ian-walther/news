defmodule Newspaper.Repo.Migrations.AddFeedCacheValidators do
  use Ecto.Migration

  def change do
    alter table(:input_feeds) do
      add :etag, :text
      add :last_modified, :text
    end
  end
end
