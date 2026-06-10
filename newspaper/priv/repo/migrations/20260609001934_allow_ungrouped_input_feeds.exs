defmodule Newspaper.Repo.Migrations.AllowUngroupedInputFeeds do
  use Ecto.Migration

  def up do
    drop_if_exists unique_index(:articles, [:intake_group_id, :dedupe_key])

    execute "ALTER TABLE input_feeds ALTER COLUMN intake_group_id DROP NOT NULL"
    execute "ALTER TABLE raw_items ALTER COLUMN intake_group_id DROP NOT NULL"

    alter table(:articles) do
      add :dedupe_scope, :text
    end

    execute "ALTER TABLE articles ALTER COLUMN intake_group_id DROP NOT NULL"

    execute """
    UPDATE articles
    SET dedupe_scope = 'group:' || intake_group_id::text
    WHERE intake_group_id IS NOT NULL
    """

    execute """
    UPDATE articles
    SET dedupe_scope = 'feed:' || raw_items.input_feed_id::text
    FROM raw_items
    WHERE articles.dedupe_scope IS NULL
      AND articles.representative_raw_item_id = raw_items.id
    """

    execute """
    UPDATE articles
    SET dedupe_scope = 'article:' || id::text
    WHERE dedupe_scope IS NULL
    """

    alter table(:articles) do
      modify :dedupe_scope, :text, null: false
    end

    create unique_index(:articles, [:dedupe_scope, :dedupe_key])
  end

  def down do
    drop_if_exists unique_index(:articles, [:dedupe_scope, :dedupe_key])

    execute """
    DELETE FROM articles
    WHERE intake_group_id IS NULL
    """

    execute """
    DELETE FROM raw_items
    WHERE intake_group_id IS NULL
    """

    execute """
    DELETE FROM input_feeds
    WHERE intake_group_id IS NULL
    """

    alter table(:articles) do
      remove :dedupe_scope
    end

    execute "ALTER TABLE articles ALTER COLUMN intake_group_id SET NOT NULL"
    execute "ALTER TABLE raw_items ALTER COLUMN intake_group_id SET NOT NULL"
    execute "ALTER TABLE input_feeds ALTER COLUMN intake_group_id SET NOT NULL"

    create unique_index(:articles, [:intake_group_id, :dedupe_key])
  end
end
