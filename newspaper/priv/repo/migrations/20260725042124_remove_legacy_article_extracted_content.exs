defmodule Newspaper.Repo.Migrations.RemoveLegacyArticleExtractedContent do
  use Ecto.Migration

  def up do
    execute("""
    INSERT INTO article_extractions (
      article_id,
      implementation_key,
      final_url,
      title,
      byline,
      content_html,
      content_text,
      quality,
      debug_metadata,
      extracted_at,
      inserted_at,
      updated_at
    )
    SELECT
      article.id,
      'legacy.article_cache',
      article.resolved_url,
      article.title,
      article.author,
      article.extracted_content,
      article.extracted_content,
      '{}'::jsonb,
      '{"migrated_from":"articles.extracted_content"}'::jsonb,
      COALESCE(article.updated_at, article.inserted_at, NOW()),
      COALESCE(article.inserted_at, NOW()),
      COALESCE(article.updated_at, article.inserted_at, NOW())
    FROM articles AS article
    LEFT JOIN article_extractions AS extraction ON extraction.article_id = article.id
    WHERE extraction.id IS NULL
      AND NULLIF(article.extracted_content, '') IS NOT NULL
    """)

    alter table(:articles) do
      remove :extracted_content
    end
  end

  def down do
    alter table(:articles) do
      add :extracted_content, :text
    end

    execute("""
    UPDATE articles AS article
    SET extracted_content = extraction.content_html
    FROM article_extractions AS extraction
    WHERE extraction.article_id = article.id
    """)
  end
end
