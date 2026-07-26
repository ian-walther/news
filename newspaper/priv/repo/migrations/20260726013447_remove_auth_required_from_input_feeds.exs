defmodule Newspaper.Repo.Migrations.RemoveAuthRequiredFromInputFeeds do
  use Ecto.Migration

  def change do
    alter table(:input_feeds) do
      remove :auth_required, :boolean, null: false, default: false
    end
  end
end
