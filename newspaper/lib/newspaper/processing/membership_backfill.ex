defmodule Newspaper.Processing.MembershipBackfill do
  @moduledoc """
  The SQL that reconstructs durable batch membership, lineage, and
  participation from the pre-membership schema (attempts that carry
  `batch_run_id`). Kept as a module so the upgrade can be exercised by tests
  against representative pre-change rows, not only run once by the migration
  (audit IMP-20).

  Policy — what the old schema can prove, and what it cannot:

  - **Finished batches.** A member is an item step of the batch's own output
    feed and step type that a batch-owned attempt was created for, or that
    still points at one. Its outcome is that attempt's own terminal status
    (the latest batch-owned attempt for the item step), never the item
    step's current state: later independent work on the same article is not
    this batch's record. Enrollment time is the attempt's creation time.
  - **Running batches: live demand.** A running batch's request is its own
    feed's items. Every same-feed, same-step item step that is live
    (queued/running, or failed on a retryable rate limit whose automatic
    retry the runtime's budget will re-check) and whose current attempt
    started after the batch began is treated as the batch's open member,
    whoever owns that attempt — an item enrolled through another feed's
    shared execution is still this batch's demand, and so is a legacy
    automatic retry of a member whose earlier batch-owned attempt failed,
    whether that retry already exists or recovery will create it (that
    member is reopened rather than frozen as failed). The only
    misattribution this admits is a manual foreground request on the
    batch's feed made while it ran, which the batch then waits for; that is
    preferred over dropping real demand.
  - **Running batches: unrecoverable.** A running batch that ends up with no
    members has no verifiable request left in the old schema (its enrollment
    never got far enough to leave evidence). It is closed as `failed` with an
    error summary that says so; its outstanding items remain under the
    pipeline and the operator starts the batch again. Missing evidence is
    never turned into a successful completion.
  - **Lineage** holds batch-owned attempts plus the live attempts claimed for
    running batches; participation holds every attempt an item step was
    created for or currently points at.
  - Historical entry failures already repaired are resolved.
  """

  def member_statements do
    [
      """
      INSERT INTO pipeline_batch_members (
        batch_run_id, generated_feed_item_step_id, outcome, outcome_at, enrolled_at,
        inserted_at, updated_at
      )
      SELECT DISTINCT ON (batch.id, item_step.id)
        batch.id,
        item_step.id,
        CASE WHEN attempt.status IN ('succeeded', 'failed', 'skipped')
             THEN attempt.status ELSE NULL END,
        CASE WHEN attempt.status IN ('succeeded', 'failed', 'skipped')
             THEN attempt.finished_at ELSE NULL END,
        attempt.inserted_at,
        NOW(),
        NOW()
      FROM runs AS batch
      JOIN pipeline_step_attempts AS attempt ON attempt.batch_run_id = batch.id
      JOIN generated_feed_item_steps AS item_step
        ON item_step.step_type = attempt.step_type
       AND (item_step.id = attempt.generated_feed_item_step_id
            OR item_step.latest_attempt_id = attempt.id)
      JOIN generated_feed_items AS item ON item.id = item_step.generated_feed_item_id
      WHERE batch.run_type = 'pipeline_batch'
        AND item.generated_feed_id = (batch.related->>'generated_feed_id')::bigint
      ORDER BY batch.id, item_step.id, attempt.id DESC
      ON CONFLICT DO NOTHING
      """,
      """
      INSERT INTO pipeline_batch_members (
        batch_run_id, generated_feed_item_step_id, outcome, outcome_at, enrolled_at,
        inserted_at, updated_at
      )
      SELECT DISTINCT batch.id, item_step.id, NULL::text, NULL::timestamp,
        attempt.inserted_at, NOW(), NOW()
      FROM runs AS batch
      JOIN generated_feed_items AS item
        ON item.generated_feed_id = (batch.related->>'generated_feed_id')::bigint
      JOIN generated_feed_item_steps AS item_step
        ON item_step.generated_feed_item_id = item.id
       AND item_step.step_type = batch.related->>'step_type'
      JOIN pipeline_step_attempts AS attempt ON attempt.id = item_step.latest_attempt_id
      WHERE batch.run_type = 'pipeline_batch'
        AND batch.status = 'running'
        AND item_step.status IN ('queued', 'running')
        AND attempt.inserted_at >= batch.started_at
      ON CONFLICT DO NOTHING
      """,
      """
      UPDATE pipeline_batch_members AS member
      SET outcome = NULL, outcome_at = NULL, updated_at = NOW()
      FROM runs AS batch,
           generated_feed_item_steps AS item_step,
           pipeline_step_attempts AS attempt
      WHERE member.batch_run_id = batch.id
        AND item_step.id = member.generated_feed_item_step_id
        AND attempt.id = item_step.latest_attempt_id
        AND batch.run_type = 'pipeline_batch'
        AND batch.status = 'running'
        AND member.outcome IS NOT NULL
        AND attempt.inserted_at >= batch.started_at
        AND (item_step.status IN ('queued', 'running')
             OR (item_step.status = 'failed'
                 AND attempt.status = 'failed'
                 AND attempt.retryable
                 AND attempt.failure_kind = 'rate_limited'))
      """,
      """
      UPDATE runs AS batch
      SET status = 'failed',
          finished_at = NOW(),
          error_summary = 'Upgrade could not recover this batch''s membership; its outstanding items are still queued or waiting under the pipeline — start the batch again to track them',
          updated_at = NOW()
      WHERE batch.run_type = 'pipeline_batch'
        AND batch.status = 'running'
        AND NOT EXISTS (
          SELECT 1 FROM pipeline_batch_members AS member WHERE member.batch_run_id = batch.id
        )
      """
    ]
  end

  def lineage_statements do
    [
      """
      INSERT INTO pipeline_batch_attempts (batch_run_id, pipeline_step_attempt_id, inserted_at)
      SELECT DISTINCT attempt.batch_run_id, attempt.id, NOW()
      FROM pipeline_step_attempts AS attempt
      WHERE attempt.batch_run_id IS NOT NULL
      ON CONFLICT DO NOTHING
      """,
      """
      INSERT INTO pipeline_batch_attempts (batch_run_id, pipeline_step_attempt_id, inserted_at)
      SELECT DISTINCT member.batch_run_id, item_step.latest_attempt_id, NOW()
      FROM pipeline_batch_members AS member
      JOIN runs AS batch ON batch.id = member.batch_run_id
      JOIN generated_feed_item_steps AS item_step ON item_step.id = member.generated_feed_item_step_id
      WHERE batch.status = 'running'
        AND member.outcome IS NULL
        AND item_step.latest_attempt_id IS NOT NULL
      ON CONFLICT DO NOTHING
      """
    ]
  end

  def participation_statements do
    [
      """
      INSERT INTO pipeline_item_step_attempts (
        generated_feed_item_step_id, pipeline_step_attempt_id, inserted_at
      )
      SELECT DISTINCT attempt.generated_feed_item_step_id, attempt.id, NOW()
      FROM pipeline_step_attempts AS attempt
      WHERE attempt.generated_feed_item_step_id IS NOT NULL
      ON CONFLICT DO NOTHING
      """,
      """
      INSERT INTO pipeline_item_step_attempts (
        generated_feed_item_step_id, pipeline_step_attempt_id, inserted_at
      )
      SELECT DISTINCT item_step.id, item_step.latest_attempt_id, NOW()
      FROM generated_feed_item_steps AS item_step
      WHERE item_step.latest_attempt_id IS NOT NULL
      ON CONFLICT DO NOTHING
      """
    ]
  end

  @doc """
  Historical entry failures that a later fetch already repaired must not
  surface as newly actionable once `resolved_at` exists.
  """
  def resolution_statements do
    [
      """
      UPDATE failures AS failure
      SET resolved_at = NOW()
      WHERE failure.resolved_at IS NULL
        AND failure.failure_type = 'raw_item_ingestion_failed'
        AND EXISTS (
          SELECT 1 FROM raw_items AS raw
          WHERE raw.input_feed_id = (failure.related->>'input_feed_id')::bigint
            AND (raw.feed_guid = failure.related->>'feed_guid' OR raw.url = failure.related->>'url')
        )
      """,
      """
      UPDATE failures AS failure
      SET resolved_at = NOW()
      WHERE failure.resolved_at IS NULL
        AND failure.failure_type = 'raw_item_processing_failed'
        AND EXISTS (
          SELECT 1 FROM articles AS article
          WHERE article.representative_raw_item_id = (failure.related->>'raw_item_id')::bigint
        )
      """,
      """
      UPDATE failures AS failure
      SET resolved_at = NOW()
      WHERE failure.resolved_at IS NULL
        AND failure.failure_type = 'generated_feed_item_create_failed'
        AND EXISTS (
          SELECT 1 FROM generated_feed_items AS item
          WHERE item.generated_feed_id = (failure.related->>'generated_feed_id')::bigint
            AND item.article_id = (failure.related->>'article_id')::bigint
        )
      """
    ]
  end

  def run_all(repo) do
    for sql <-
          member_statements() ++
            lineage_statements() ++ participation_statements() ++ resolution_statements() do
      repo.query!(sql)
    end

    :ok
  end
end
