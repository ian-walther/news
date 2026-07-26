defmodule Newspaper.Repo.Migrations.DefaultHostedArticleDigestsToHidden do
  use Ecto.Migration

  def up do
    alter table(:generated_feeds) do
      modify :show_digest_in_hosted_article, :boolean, null: false, default: false
    end

    execute("UPDATE generated_feeds SET show_digest_in_hosted_article = FALSE")
  end

  def down do
    alter table(:generated_feeds) do
      modify :show_digest_in_hosted_article, :boolean, null: false, default: true
    end
  end
end
