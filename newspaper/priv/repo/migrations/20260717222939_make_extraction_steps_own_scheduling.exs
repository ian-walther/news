defmodule Newspaper.Repo.Migrations.MakeExtractionStepsOwnScheduling do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE pipeline_steps AS step
    SET enabled = FALSE,
        updated_at = NOW()
    FROM generated_feeds AS feed
    WHERE step.generated_feed_id = feed.id
      AND step.step_type = 'extraction'
      AND feed.process_items = FALSE
      AND step.enabled = TRUE
    """)

    execute("""
    UPDATE generated_feeds
    SET link_to_hosted_article = FALSE,
        use_extracted_content_body = FALSE,
        updated_at = NOW()
    WHERE process_items = FALSE
    """)

    alter table(:generated_feeds) do
      remove :process_items
    end
  end

  def down do
    alter table(:generated_feeds) do
      add :process_items, :boolean, null: false, default: false
    end

    flush()

    execute("""
    UPDATE generated_feeds AS feed
    SET process_items = TRUE
    WHERE feed.link_to_hosted_article = TRUE
       OR feed.use_extracted_content_body = TRUE
       OR EXISTS (
         SELECT 1
         FROM pipeline_steps AS step
         WHERE step.generated_feed_id = feed.id
           AND step.step_type = 'extraction'
           AND step.enabled = TRUE
       )
    """)
  end
end
