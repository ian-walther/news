defmodule Newspaper.Repo.Migrations.AddShowDigestInHostedArticleToGeneratedFeeds do
  use Ecto.Migration

  def change do
    alter table(:generated_feeds) do
      add :show_digest_in_hosted_article, :boolean, null: false, default: true
    end
  end
end
