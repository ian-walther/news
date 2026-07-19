defmodule Newspaper.Repo.Migrations.ClassifyNoContentAsSkipped do
  use Ecto.Migration

  def up do
    execute """
    UPDATE article_extraction_attempts
    SET status = 'no_content',
        failure_kind = NULL,
        retryable = FALSE,
        output_snapshot = (output_snapshot - 'failure_kind' - 'retryable') ||
          jsonb_build_object(
            'status', 'no_content',
            'reason', COALESCE(output_snapshot->>'reason', 'insufficient_content')
          ),
        updated_at = NOW()
    WHERE status = 'failed'
      AND failure_kind = 'insufficient_content'
      AND retryable = FALSE
    """

    execute """
    UPDATE pipeline_step_attempts
    SET status = 'skipped',
        failure_kind = NULL,
        retryable = FALSE,
        error_message = NULL,
        output_snapshot = (output_snapshot - 'failure_kind' - 'retryable') ||
          jsonb_build_object(
            'status', 'no_content',
            'reason', COALESCE(output_snapshot->>'reason', 'insufficient_content')
          ),
        updated_at = NOW()
    WHERE status = 'failed'
      AND failure_kind = 'insufficient_content'
      AND retryable = FALSE
    """

    execute """
    UPDATE articles
    SET extraction_status = 'skipped',
        extraction_metadata = (extraction_metadata - 'failure_kind' - 'retryable') ||
          jsonb_build_object(
            'status', 'no_content',
            'reason', COALESCE(extraction_metadata->>'reason', 'insufficient_content')
          ),
        updated_at = NOW()
    WHERE extraction_status = 'failed'
      AND extraction_metadata->>'failure_kind' = 'insufficient_content'
      AND COALESCE((extraction_metadata->>'retryable')::boolean, FALSE) = FALSE
    """

    execute """
    UPDATE generated_feed_item_steps AS item_step
    SET status = 'skipped',
        error_message = NULL,
        finished_at = COALESCE(item_step.finished_at, NOW()),
        updated_at = NOW()
    FROM generated_feed_items AS item
    JOIN articles AS article ON article.id = item.article_id
    WHERE item_step.generated_feed_item_id = item.id
      AND item_step.step_type = 'extraction'
      AND item_step.status = 'failed'
      AND article.extraction_status = 'skipped'
      AND article.extraction_metadata->>'status' = 'no_content'
    """

    execute """
    UPDATE site_extraction_policies
    SET last_failure_kind = NULL,
        consecutive_rate_limits = 0,
        backoff_until = NULL,
        updated_at = NOW()
    WHERE last_failure_kind = 'insufficient_content'
    """

    execute """
    DELETE FROM failures AS failure
    USING pipeline_step_attempts AS attempt
    WHERE failure.failure_type = 'pipeline_step_insufficient_content'
      AND failure.related->>'pipeline_step_attempt_id' = attempt.id::text
      AND attempt.status = 'skipped'
      AND attempt.output_snapshot->>'status' = 'no_content'
    """

    execute """
    UPDATE runs AS run
    SET status = 'succeeded',
        summary_counts = jsonb_build_object(
          'attempts', 1,
          'succeeded', 0,
          'failed', 0,
          'skipped', 1
        ),
        error_summary = NULL,
        updated_at = NOW()
    FROM pipeline_step_attempts AS attempt
    WHERE run.pipeline_step_attempt_id = attempt.id
      AND attempt.status = 'skipped'
      AND attempt.output_snapshot->>'status' = 'no_content'
    """

    execute """
    WITH affected_batches AS (
      SELECT DISTINCT batch_run_id
      FROM pipeline_step_attempts
      WHERE batch_run_id IS NOT NULL
        AND status = 'skipped'
        AND output_snapshot->>'status' = 'no_content'
    ),
    counts AS (
      SELECT
        attempt.batch_run_id,
        COUNT(*) FILTER (WHERE attempt.status = 'queued') AS queued,
        COUNT(*) FILTER (WHERE attempt.status = 'running') AS running,
        COUNT(*) FILTER (WHERE attempt.status = 'succeeded') AS succeeded,
        COUNT(*) FILTER (WHERE attempt.status = 'failed') AS failed,
        COUNT(*) FILTER (WHERE attempt.status = 'skipped') AS skipped,
        COUNT(*) AS total
      FROM pipeline_step_attempts AS attempt
      WHERE attempt.batch_run_id IN (SELECT batch_run_id FROM affected_batches)
      GROUP BY attempt.batch_run_id
    )
    UPDATE runs AS run
    SET status = CASE
          WHEN counts.queued + counts.running > 0 THEN 'running'
          WHEN counts.failed > 0 THEN 'failed'
          ELSE 'succeeded'
        END,
        summary_counts = jsonb_build_object(
          'queued', counts.queued,
          'running', counts.running,
          'succeeded', counts.succeeded,
          'failed', counts.failed,
          'skipped', counts.skipped + GREATEST(
            COALESCE((run.summary_counts->>'items_considered')::integer, counts.total) - counts.total,
            0
          ),
          'total', counts.total,
          'items_considered', COALESCE(
            (run.summary_counts->>'items_considered')::integer,
            counts.total
          )
        ),
        error_summary = CASE WHEN counts.failed = 0 THEN NULL ELSE run.error_summary END,
        updated_at = NOW()
    FROM counts
    WHERE run.id = counts.batch_run_id
    """
  end

  def down do
    raise "classifying no-content extraction outcomes as skipped is irreversible"
  end
end
