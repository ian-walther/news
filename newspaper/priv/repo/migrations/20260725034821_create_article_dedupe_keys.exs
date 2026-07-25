defmodule Newspaper.Repo.Migrations.CreateArticleDedupeKeys do
  use Ecto.Migration

  def up do
    create table(:article_dedupe_keys) do
      add :article_id, references(:articles, on_delete: :delete_all), null: false
      add :dedupe_scope, :text, null: false
      add :dedupe_key, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:article_dedupe_keys, [:dedupe_scope, :dedupe_key])
    create index(:article_dedupe_keys, [:article_id])

    execute """
    INSERT INTO article_dedupe_keys (
      article_id,
      dedupe_scope,
      dedupe_key,
      inserted_at,
      updated_at
    )
    SELECT id, dedupe_scope, dedupe_key, NOW(), NOW()
    FROM articles
    """

    execute """
    INSERT INTO article_dedupe_keys (
      article_id,
      dedupe_scope,
      dedupe_key,
      inserted_at,
      updated_at
    )
    SELECT DISTINCT ON (article.dedupe_scope, raw_item.feed_guid)
      article.id,
      article.dedupe_scope,
      'feed_guid:' || raw_item.feed_guid,
      NOW(),
      NOW()
    FROM articles AS article
    JOIN article_sources AS article_source ON article_source.article_id = article.id
    JOIN raw_items AS raw_item ON raw_item.id = article_source.raw_item_id
    WHERE NULLIF(raw_item.feed_guid, '') IS NOT NULL
    ORDER BY
      article.dedupe_scope,
      raw_item.feed_guid,
      article.inserted_at,
      article.id
    ON CONFLICT (dedupe_scope, dedupe_key) DO NOTHING
    """
  end

  def down do
    drop table(:article_dedupe_keys)
  end
end
