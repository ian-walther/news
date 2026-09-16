defmodule Newspaper.Processing do
  import Ecto.Query

  @automatic_rate_limit_retries 3

  alias Newspaper.Content
  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction}
  alias Newspaper.Digestion
  alias Newspaper.Operations
  alias Newspaper.Operations.Run

  alias Newspaper.Processing.{
    BatchDispatcher,
    GeneratedFeedItemStep,
    PipelineBatchAttempt,
    PipelineBatchMember,
    PipelineItemStepAttempt,
    PipelineStep,
    PipelineStepAttempt,
    PriorityQueue,
    Registry
  }

  @batch_selections [:not_requested, :failed, :cancelled]
  @terminal_item_statuses ["succeeded", "failed", "skipped", "cancelled"]
  @cancellable_item_statuses ["not_requested", "pending", "blocked", "queued"]
  # Item steps that still demand their execution. A cancelled row keeps its
  # attempt link for history but is not demand: execution state never flows
  # back into it (audit IMP-03).
  @live_item_statuses ["pending", "blocked", "queued", "running"]

  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Repo

  def list_steps(%GeneratedFeed{id: feed_id}), do: list_steps(feed_id)

  def list_steps(feed_id) when is_integer(feed_id) do
    PipelineStep
    |> where([step], step.generated_feed_id == ^feed_id)
    |> order_by([step], asc: step.position, asc: step.id)
    |> Repo.all()
  end

  def list_enabled_steps(feed_id, step_type) do
    PipelineStep
    |> where(
      [step],
      step.generated_feed_id == ^feed_id and step.step_type == ^step_type and
        step.enabled == true
    )
    |> order_by([step], asc: step.position, asc: step.id)
    |> Repo.all()
  end

  def list_enabled_steps(feed_id) when is_integer(feed_id) do
    PipelineStep
    |> where([step], step.generated_feed_id == ^feed_id and step.enabled == true)
    |> order_by([step], asc: step.position, asc: step.id)
    |> Repo.all()
  end

  def step_eligible_article_ids([], _step_type), do: MapSet.new()

  def step_eligible_article_ids(article_ids, step_type)
      when is_list(article_ids) and is_binary(step_type) do
    GeneratedFeedItem
    |> join(:inner, [item], feed in GeneratedFeed, on: feed.id == item.generated_feed_id)
    |> join(:inner, [_item, feed], step in PipelineStep,
      on:
        step.generated_feed_id == feed.id and step.step_type == ^step_type and
          step.enabled == true
    )
    |> where([item, feed, _step], item.article_id in ^article_ids and feed.enabled == true)
    |> select([item, _feed, _step], item.article_id)
    |> distinct(true)
    |> Repo.all()
    |> MapSet.new()
  end

  def get_step!(id), do: Repo.get!(PipelineStep, id)

  def enqueue_item(%GeneratedFeedItem{} = item, opts \\ []) do
    mode = if Keyword.get(opts, :force, false), do: :requested, else: :future

    with {:ok, _item_steps} <- ensure_item_steps(item, mode),
         {:ok, attempts} <- advance_item(item.id, opts) do
      {:ok, attempts}
    end
  end

  def start_feed_batch(feed_id, trigger \\ "manual", step_type \\ "extraction", opts \\ [])

  def start_feed_batch(feed_id, trigger, step_type, opts)
      when is_integer(feed_id) and is_binary(step_type) and is_list(opts) do
    feed = Newspaper.Publishing.get_generated_feed!(feed_id)
    steps = list_enabled_steps(feed.id, step_type)
    selection = Keyword.get(opts, :selection, :not_requested)

    with :ok <- ensure_batch_step_enabled(steps, step_type),
         :ok <- ensure_batch_selection(selection),
         :ok <- ensure_no_running_batch(feed.id, step_type),
         :ok <- ensure_batch_runnable(step_type),
         {:ok, batch} <- create_batch_with_members(feed, steps, trigger, step_type, selection) do
      case BatchDispatcher.enqueue(batch.id) do
        :ok ->
          {:ok, batch}

        {:error, reason} ->
          _ = fail_feed_batch(batch.id, reason)
          {:error, reason}
      end
    end
  end

  defp ensure_batch_step_enabled([], step_type), do: {:error, {:no_enabled_step, step_type}}
  defp ensure_batch_step_enabled(_steps, _step_type), do: :ok

  defp ensure_batch_selection(selection) when selection in @batch_selections, do: :ok
  defp ensure_batch_selection({:items, ids}) when is_list(ids), do: :ok
  defp ensure_batch_selection(selection), do: {:error, {:invalid_batch_selection, selection}}

  defp ensure_no_running_batch(feed_id, step_type) do
    if Map.has_key?(active_batches_by_feed_step(), {feed_id, step_type}),
      do: {:error, :batch_already_running},
      else: :ok
  end

  defp ensure_batch_runnable("digestion") do
    settings = Operations.get_settings()

    cond do
      settings.digestion_paused -> {:error, :digestion_paused}
      true -> ensure_requirements("digestion")
    end
  end

  defp ensure_batch_runnable(step_type), do: ensure_requirements(step_type)

  # The complete intended membership is persisted with the run in one
  # transaction, under a per-feed/step advisory lock, before anything is
  # dispatched (audit IMP-06). Enrollment, cancellation, and recovery then all
  # read the same durable demand.
  defp create_batch_with_members(feed, steps, trigger, step_type, selection) do
    Repo.transaction(fn ->
      lock_feed_step!(feed.id, step_type)

      with :ok <- ensure_no_running_batch(feed.id, step_type),
           {:ok, item_step_ids} <- resolve_batch_members(feed, step_type, selection),
           {:ok, batch} <- create_feed_batch(feed, steps, trigger, step_type, selection) do
        now = DateTime.utc_now(:second)

        rows =
          Enum.map(item_step_ids, fn item_step_id ->
            %{
              batch_run_id: batch.id,
              generated_feed_item_step_id: item_step_id,
              inserted_at: now,
              updated_at: now
            }
          end)

        Repo.insert_all(PipelineBatchMember, rows, on_conflict: :nothing)
        batch
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The demand lock for a feed/step: requests take it shared; batch creation,
  # step removal, and disabling take it exclusively so they never race new
  # demand (audit IMP-06A).
  defp lock_feed_step!(feed_id, step_type, mode \\ :exclusive) do
    key = :erlang.phash2({:pipeline_batch, feed_id, step_type})

    case mode do
      :exclusive -> Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
      :shared -> Repo.query!("SELECT pg_advisory_xact_lock_shared($1)", [key])
    end

    :ok
  end

  # Explicit item selections are validated server-side against the feed, the
  # step, and a retryable status; stale or foreign ids are dropped silently.
  defp resolve_batch_members(feed, step_type, {:items, ids}) do
    ids = ids |> Enum.map(&to_integer_id/1) |> Enum.reject(&is_nil/1)

    item_step_ids =
      GeneratedFeedItemStep
      |> join(:inner, [item_step], item in GeneratedFeedItem,
        on: item.id == item_step.generated_feed_item_id
      )
      |> where(
        [item_step, item],
        item_step.id in ^ids and item.generated_feed_id == ^feed.id and
          item_step.step_type == ^step_type and
          item_step.status in ["failed", "cancelled", "not_requested"]
      )
      |> select([item_step], item_step.id)
      |> Repo.all()

    if item_step_ids == [], do: {:error, :no_eligible_items}, else: {:ok, item_step_ids}
  end

  defp resolve_batch_members(feed, step_type, selection) when is_atom(selection) do
    status = Atom.to_string(selection)

    item_step_ids =
      GeneratedFeedItemStep
      |> join(:inner, [item_step], item in GeneratedFeedItem,
        on: item.id == item_step.generated_feed_item_id
      )
      |> where(
        [item_step, item],
        item.generated_feed_id == ^feed.id and item_step.step_type == ^step_type and
          item_step.status == ^status
      )
      |> order_by([item_step, item], asc: item.id)
      |> select([item_step], item_step.id)
      |> Repo.all()

    # An empty status selection is a legitimate "nothing to do" batch.
    {:ok, item_step_ids}
  end

  defp to_integer_id(id) when is_integer(id), do: id

  defp to_integer_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp to_integer_id(_id), do: nil

  def list_running_feed_batches do
    Run
    |> where([run], run.run_type == "pipeline_batch" and run.status == "running")
    |> order_by([run], asc: run.started_at, asc: run.id)
    |> Repo.all()
  end

  def resume_feed_batch(batch_id) when is_integer(batch_id) do
    batch = Operations.get_run!(batch_id)

    cond do
      batch.run_type != "pipeline_batch" or batch.status != "running" ->
        {:ok, batch}

      batch_cancelled?(batch) ->
        refresh_batch_run(batch.id)

      true ->
        with {:ok, _feed_id, step_type, selection} <- feed_batch_context(batch),
             :ok <- ensure_membership_recoverable(batch),
             members <- batch_enrollment_members(batch),
             :ok <- enqueue_batch_members(members, batch.id, step_type, selection),
             {:ok, batch} <- refresh_batch_run(batch.id) do
          {:ok, batch}
        else
          {:error, reason} -> fail_feed_batch(batch.id, reason)
        end
    end
  end

  # A batch created by this code records that its membership was written with
  # it. A running batch without that marker and without members is a legacy
  # request whose membership the upgrade could not recover; it fails with a
  # clear reason instead of finishing as an empty success (audit IMP-20B).
  defp ensure_membership_recoverable(batch) do
    cond do
      batch.related["members_snapshotted"] == true -> :ok
      Repo.exists?(from m in PipelineBatchMember, where: m.batch_run_id == ^batch.id) -> :ok
      true -> {:error, :membership_unrecoverable}
    end
  end

  @doc """
  Cancels a batch: withdraws every not-yet-started member (and, cascading,
  the not-yet-started downstream steps of the same items), skips attempts
  that no longer have any demand, removes them from the dispatchers, and
  closes the run once nothing is running. Running attempts finish normally.
  Repeated cancellation is a no-op.
  """
  def cancel_feed_batch(batch_id) when is_integer(batch_id) do
    batch = Operations.get_run!(batch_id)

    cond do
      batch.run_type != "pipeline_batch" ->
        {:error, :not_a_batch}

      batch_cancelled?(batch) ->
        {:ok, %{batch: batch, cancelled: %{}, running: 0, attempt_ids: []}}

      true ->
        {:ok, result} = Repo.transaction(fn -> cancel_batch_members!(batch) end)
        Newspaper.Processing.Dispatcher.remove(result.attempt_ids)
        Newspaper.Digestion.Dispatcher.remove(result.attempt_ids)
        {:ok, batch} = refresh_batch_run(batch.id)
        Newspaper.Events.broadcast_data_changed(:processing_changed)
        {:ok, %{result | batch: batch}}
    end
  end

  # A finished or cancelled batch is history; new work never joins it.
  defp batch_running?(nil), do: false

  defp batch_running?(batch_id) when is_integer(batch_id) do
    case Repo.get(Run, batch_id) do
      %Run{status: "running"} = batch -> not batch_cancelled?(batch)
      _batch -> false
    end
  end

  def batch_cancelled?(%Run{related: related}), do: is_binary(related["cancelled_at"])

  def batch_cancelled?(nil), do: false

  def batch_cancelled?(batch_id) when is_integer(batch_id) do
    case Repo.get(Run, batch_id) do
      nil -> false
      batch -> batch_cancelled?(batch)
    end
  end

  defp cancel_batch_members!(batch) do
    now = DateTime.utc_now(:second)

    # The batch row is locked for the whole cancellation; requests hold it
    # shared while they enroll, so neither can interleave with the other.
    batch = Repo.one!(from run in Run, where: run.id == ^batch.id, lock: "FOR UPDATE")

    if batch_cancelled?(batch) do
      %{batch: batch, cancelled: %{}, running: 0, attempt_ids: []}
    else
      do_cancel_batch_members!(batch, now)
    end
  end

  defp do_cancel_batch_members!(batch, now) do
    {:ok, _batch} =
      Operations.update_run(batch, %{
        related: Map.put(batch.related, "cancelled_at", DateTime.to_iso8601(now))
      })

    member_item_steps =
      GeneratedFeedItemStep
      |> join(:inner, [item_step], member in PipelineBatchMember,
        on: member.generated_feed_item_step_id == item_step.id
      )
      |> join(:left, [item_step, _member], attempt in PipelineStepAttempt,
        on: attempt.id == item_step.latest_attempt_id
      )
      |> where([_item_step, member], member.batch_run_id == ^batch.id)
      |> select([item_step, member, attempt], {item_step, member, attempt})
      |> Repo.all()

    # A member that enrollment never reached is withdrawn as a member; its
    # item step is cancelled too when it was unstarted (so one re-run covers
    # the whole cancelled selection), but a prior failure stays a failure.
    unenrolled_ids =
      for {item_step, %{outcome: nil, enrolled_at: nil}, _attempt} <- member_item_steps,
          do: item_step.id

    # Unstarted members are withdrawn; so is a failed enrolled member whose
    # automatic retry has not been queued yet. Running members finish
    # (audit IMP-02/05).
    active_item_steps =
      for {item_step, %{outcome: nil, enrolled_at: enrolled_at}, attempt} <- member_item_steps,
          item_step.status in @cancellable_item_statuses or
            (not is_nil(enrolled_at) and retry_pending?(item_step, attempt)),
          do: item_step

    # Downstream demand is withdrawn for every requested member, whether its
    # own step is unstarted, running, or already done (audit IMP-04).
    downstream_item_steps =
      member_item_steps
      |> Enum.map(fn {item_step, _member, _attempt} -> item_step end)
      |> downstream_cancellable_item_steps()

    candidates = Enum.uniq_by(active_item_steps ++ downstream_item_steps, & &1.id)

    # A worker on another connection may have claimed a candidate's attempt
    # since the snapshot above. Lock those attempts (a concurrent claim then
    # waits and finds the attempt skipped) and drop every candidate whose
    # attempt is now **running**: that work runs and its member stays open
    # (audit IMP-06A). A failed attempt awaiting its automatic retry is not
    # in flight; that demand is withdrawn here (audit IMP-06C).
    claimed_attempt_ids = lock_and_list_claimed_attempts!(candidates)

    all_item_steps =
      Enum.reject(candidates, &(&1.latest_attempt_id in claimed_attempt_ids))

    item_step_ids = Enum.map(all_item_steps, & &1.id)

    # Guarded write: only rows still in a state we decided to withdraw.
    GeneratedFeedItemStep
    |> where([item_step], item_step.id in ^item_step_ids)
    |> where([item_step], item_step.status in ^(@cancellable_item_statuses ++ ["failed"]))
    |> Repo.update_all(
      set: [
        status: "cancelled",
        error_message: "Cancelled by operator",
        finished_at: now,
        updated_at: now
      ]
    )

    PipelineBatchMember
    |> where(
      [member],
      member.generated_feed_item_step_id in ^(item_step_ids ++ unenrolled_ids) and
        is_nil(member.outcome)
    )
    |> Repo.update_all(set: [outcome: "cancelled", outcome_at: now, updated_at: now])

    attempt_ids = cancel_undemanded_attempts!(all_item_steps, now)
    refresh_batches_for_item_steps(item_step_ids -- Enum.map(active_item_steps, & &1.id))

    running =
      PipelineBatchMember
      |> join(:inner, [member], item_step in GeneratedFeedItemStep,
        on: item_step.id == member.generated_feed_item_step_id
      )
      |> where(
        [member, item_step],
        member.batch_run_id == ^batch.id and is_nil(member.outcome) and
          item_step.status == "running"
      )
      |> Repo.aggregate(:count, :id)

    cancelled =
      all_item_steps
      |> Enum.group_by(& &1.step_type)
      |> Map.new(fn {step_type, steps} -> {step_type, length(steps)} end)

    %{batch: batch, cancelled: cancelled, running: running, attempt_ids: attempt_ids}
  end

  defp lock_and_list_claimed_attempts!(item_steps) do
    attempt_ids =
      item_steps |> Enum.map(& &1.latest_attempt_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if attempt_ids == [] do
      []
    else
      PipelineStepAttempt
      |> where([attempt], attempt.id in ^attempt_ids)
      |> lock("FOR UPDATE")
      |> select([attempt], {attempt.id, attempt.status})
      |> Repo.all()
      |> Enum.filter(fn {_id, status} -> status == "running" end)
      |> Enum.map(fn {id, _status} -> id end)
    end
  end

  # Downstream steps of the same items that only exist because the cancelled
  # step was expected (decided 2026-09-14: cancellation cascades).
  defp downstream_cancellable_item_steps([]), do: []

  defp downstream_cancellable_item_steps(item_steps) do
    Enum.flat_map(item_steps, fn item_step ->
      GeneratedFeedItemStep
      |> where(
        [other],
        other.generated_feed_item_id == ^item_step.generated_feed_item_id and
          other.position > ^item_step.position and
          other.status in ^@cancellable_item_statuses
      )
      |> Repo.all()
    end)
  end

  defp retry_pending?(%GeneratedFeedItemStep{status: "failed"}, %PipelineStepAttempt{} = attempt),
    do: automatic_rate_limit_retry?(attempt)

  defp retry_pending?(_item_step, _attempt), do: false

  @doc """
  Every batch a set of item steps belongs to, from durable membership. Used
  wherever an execution or item-step outcome changes so that every batch
  sharing that work is refreshed, not only the one that created the attempt
  (audit IMP-01).
  """
  def batch_ids_for_item_steps([]), do: []

  def batch_ids_for_item_steps(item_step_ids) when is_list(item_step_ids) do
    PipelineBatchMember
    |> where([member], member.generated_feed_item_step_id in ^item_step_ids)
    |> select([member], member.batch_run_id)
    |> distinct(true)
    |> Repo.all()
  end

  defp refresh_batches_for_item_steps(item_step_ids) do
    item_step_ids
    |> batch_ids_for_item_steps()
    |> Enum.each(&refresh_batch_run/1)
  end

  # Item steps of a cancelled batch that still point at `attempt` are withdrawn
  # (cancelled, member settled); the rest are live demand that keeps the
  # execution alive for other feeds or foreground requests (audit IMP-05).
  defp partition_withdrawn_consumers(attempt_id, statuses) do
    consumers =
      GeneratedFeedItemStep
      |> where(
        [item_step],
        item_step.latest_attempt_id == ^attempt_id and item_step.status in ^statuses
      )
      |> Repo.all()

    consumer_ids = Enum.map(consumers, & &1.id)

    withdrawn_ids =
      PipelineBatchMember
      |> join(:inner, [member], batch in Run, on: batch.id == member.batch_run_id)
      |> where(
        [member, batch],
        member.generated_feed_item_step_id in ^consumer_ids and is_nil(member.outcome) and
          fragment("? \\? 'cancelled_at'", batch.related)
      )
      |> select([member], member.generated_feed_item_step_id)
      |> Repo.all()
      |> MapSet.new()

    {withdrawn, live} = Enum.split_with(consumers, &MapSet.member?(withdrawn_ids, &1.id))

    if withdrawn != [] do
      now = DateTime.utc_now(:second)
      ids = Enum.map(withdrawn, & &1.id)

      GeneratedFeedItemStep
      |> where([item_step], item_step.id in ^ids)
      |> Repo.update_all(
        set: [
          status: "cancelled",
          error_message: "Cancelled by operator",
          finished_at: now,
          updated_at: now
        ]
      )

      PipelineBatchMember
      |> where([member], member.generated_feed_item_step_id in ^ids and is_nil(member.outcome))
      |> Repo.update_all(set: [outcome: "cancelled", outcome_at: now, updated_at: now])

      refresh_batches_for_item_steps(ids)
    end

    {withdrawn, live}
  end

  # An attempt is cancelled only when no item step still demands it.
  defp cancel_undemanded_attempts!(item_steps, now) do
    attempt_ids =
      item_steps |> Enum.map(& &1.latest_attempt_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    still_demanded =
      GeneratedFeedItemStep
      |> where(
        [item_step],
        item_step.latest_attempt_id in ^attempt_ids and
          item_step.status in ["pending", "blocked", "queued", "running"]
      )
      |> select([item_step], item_step.latest_attempt_id)
      |> Repo.all()
      |> MapSet.new()

    cancellable = Enum.reject(attempt_ids, &MapSet.member?(still_demanded, &1))

    PipelineStepAttempt
    |> where([attempt], attempt.id in ^cancellable and attempt.status == "queued")
    |> Repo.update_all(
      set: [
        status: "skipped",
        failure_kind: "cancelled",
        retryable: false,
        error_message: "Cancelled by operator",
        finished_at: now,
        updated_at: now
      ]
    )

    Article
    |> join(:inner, [article], attempt in PipelineStepAttempt,
      on: attempt.article_id == article.id
    )
    |> where(
      [article, attempt],
      attempt.id in ^cancellable and attempt.step_type == "extraction" and
        attempt.failure_kind == "cancelled" and article.extraction_status == "queued"
    )
    |> Repo.update_all(set: [extraction_status: "not_requested", updated_at: now])

    cancellable
  end

  def fail_feed_batch(batch_id, reason) when is_integer(batch_id) do
    case Repo.get(Run, batch_id) do
      %Run{run_type: "pipeline_batch", status: "running"} = batch ->
        Operations.finish_run(batch, "failed", %{error_summary: format_batch_error(reason)})

      %Run{} = batch ->
        {:ok, batch}

      nil ->
        {:error, :batch_not_found}
    end
  end

  def enqueue_article(article_id, opts \\ []) when is_integer(article_id) do
    enqueue_article_step(article_id, "extraction", opts)
  end

  def enqueue_article_step(article_id, step_type, opts \\ [])
      when is_integer(article_id) and is_binary(step_type) do
    GeneratedFeedItem
    |> where([item], item.article_id == ^article_id)
    |> preload([:generated_feed, article: [:extraction, :digests]])
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case request_item_step(item, step_type, Keyword.put_new(opts, :force, true)) do
        {:ok, attempts} -> {:cont, {:ok, count + length(attempts)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def list_item_steps(%GeneratedFeedItem{id: item_id}), do: list_item_steps(item_id)

  def list_item_steps(item_id) when is_integer(item_id) do
    GeneratedFeedItemStep
    |> where([item_step], item_step.generated_feed_item_id == ^item_id)
    |> order_by([item_step], asc: item_step.position, asc: item_step.id)
    |> preload([:pipeline_step, :latest_attempt, :article_extraction, :article_digest])
    |> Repo.all()
  end

  def feed_step_counts(feed_id) when is_integer(feed_id) do
    item_count =
      Repo.aggregate(
        from(item in GeneratedFeedItem, where: item.generated_feed_id == ^feed_id),
        :count,
        :id
      )

    states =
      GeneratedFeedItemStep
      |> join(:inner, [item_step], item in GeneratedFeedItem,
        on: item.id == item_step.generated_feed_item_id
      )
      |> where([_item_step, item], item.generated_feed_id == ^feed_id)
      |> group_by([item_step, _item], [item_step.pipeline_step_id, item_step.status])
      |> select(
        [item_step, _item],
        {item_step.pipeline_step_id, item_step.status, count(item_step.id)}
      )
      |> Repo.all()
      |> Enum.group_by(fn {step_id, _status, _count} -> step_id end)

    feed_id
    |> list_steps()
    |> Map.new(fn step ->
      status_counts =
        states
        |> Map.get(step.id, [])
        |> Map.new(fn {_step_id, status, count} -> {status, count} end)

      represented = Enum.sum(Map.values(status_counts))
      missing = max(item_count - represented, 0)

      counts = %{
        total: item_count,
        ready: Map.get(status_counts, "succeeded", 0),
        not_requested: Map.get(status_counts, "not_requested", 0) + missing,
        pending: Map.get(status_counts, "pending", 0),
        blocked: Map.get(status_counts, "blocked", 0),
        queued: Map.get(status_counts, "queued", 0),
        running: Map.get(status_counts, "running", 0),
        failed: Map.get(status_counts, "failed", 0),
        skipped: Map.get(status_counts, "skipped", 0),
        cancelled: Map.get(status_counts, "cancelled", 0)
      }

      {step.id, counts}
    end)
  end

  @doc """
  Requests `step_type` for an item. The write path runs in one transaction
  that holds the feed/step demand lock (shared) and, for batch work, a row
  lock on the batch run, re-checking cancellation under that lock — so a
  cancellation that commits after the first check cannot be followed by new
  work, and structural changes to the step wait for in-flight requests
  (audit IMP-06A). Dispatch to the queues happens after commit.
  """
  def request_item_step(%GeneratedFeedItem{} = item, step_type, opts \\ []) do
    batch_run_id = Keyword.get(opts, :batch_run_id)

    # Cheap early-out; the authoritative check is under the lock below.
    if batch_cancelled?(batch_run_id) do
      {:error, :batch_cancelled}
    else
      with_deferred_dispatch(fn ->
        Repo.transaction(fn ->
          lock_feed_step!(item.generated_feed_id, step_type, :shared)

          with :ok <- lock_batch_demand(batch_run_id),
               {:ok, attempts} <- do_request_item_step(item, step_type, opts) do
            attempts
          else
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
      end)
    end
  end

  defp lock_batch_demand(nil), do: :ok

  defp lock_batch_demand(batch_run_id) do
    case Repo.one(from run in Run, where: run.id == ^batch_run_id, lock: "FOR SHARE") do
      nil ->
        {:error, :batch_not_found}

      %Run{} = batch ->
        if batch_cancelled?(batch), do: {:error, :batch_cancelled}, else: running_batch(batch)
    end
  end

  defp running_batch(%Run{status: "running"}), do: :ok
  defp running_batch(_batch), do: {:error, :batch_finished}

  # Queue dispatch must not precede the commit that makes the attempt
  # claimable; the outermost request flushes it afterwards.
  @deferred_dispatch_key :newspaper_deferred_dispatch

  defp with_deferred_dispatch(fun) do
    if is_list(Process.get(@deferred_dispatch_key)) do
      fun.()
    else
      Process.put(@deferred_dispatch_key, [])

      try do
        result = fun.()

        if match?({:ok, _}, result) do
          @deferred_dispatch_key
          |> Process.get([])
          |> Enum.reverse()
          |> Enum.each(fn {attempt, article} -> dispatch(attempt, article) end)
        end

        result
      after
        Process.delete(@deferred_dispatch_key)
      end
    end
  end

  defp dispatch_after_commit(attempt, article) do
    case Process.get(@deferred_dispatch_key) do
      deferred when is_list(deferred) ->
        Process.put(@deferred_dispatch_key, [{attempt, article} | deferred])

      _ ->
        dispatch(attempt, article)
    end
  end

  defp do_request_item_step(item, step_type, opts) do
    mode = if Keyword.get(opts, :force, false), do: :force, else: :requested

    advance_opts =
      if mode == :force, do: Keyword.put(opts, :force_step_type, step_type), else: opts

    with [step] <- list_enabled_steps(item.generated_feed_id, step_type),
         :ok <- reconcile_prior_steps(item, step),
         {:ok, _item_step} <- ensure_item_step(item, step, mode),
         :ok <- maybe_revive_downstream(item, step, opts),
         {:ok, attempts} <- advance_item(item.id, advance_opts) do
      {:ok, attempts}
    else
      [] -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  # "Run on cancelled items" re-creates the downstream demand that was
  # cancelled with the requested step, so cancel/re-queue is reversible.
  defp maybe_revive_downstream(item, step, opts) do
    if Keyword.get(opts, :revive_downstream, false) do
      item = Repo.preload(item, [article: [:extraction, :digests]], force: true)

      GeneratedFeedItemStep
      |> where(
        [item_step],
        item_step.generated_feed_item_id == ^item.id and item_step.position > ^step.position and
          item_step.status == "cancelled"
      )
      |> Repo.all()
      |> Enum.each(fn item_step ->
        update_item_step!(item_step, %{
          status: requested_status(item.article, item_step.step_type),
          error_message: nil,
          latest_attempt_id: nil,
          started_at: nil,
          finished_at: nil
        })
      end)
    end

    :ok
  end

  defp reconcile_prior_steps(item, requested_step) do
    item.generated_feed_id
    |> list_enabled_steps()
    |> Enum.take_while(&(&1.position < requested_step.position))
    |> Enum.reduce_while(:ok, fn step, :ok ->
      case ensure_item_step(item, step, :bookkeeping) do
        {:ok, _item_step} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ensure_item_steps(%GeneratedFeedItem{} = item, mode) when mode in [:future, :requested] do
    item.generated_feed_id
    |> list_enabled_steps()
    |> Enum.reduce_while({:ok, []}, fn step, {:ok, item_steps} ->
      case ensure_item_step(item, step, mode) do
        {:ok, item_step} -> {:cont, {:ok, [item_step | item_steps]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def ensure_item_step(%GeneratedFeedItem{} = item, %PipelineStep{} = step, mode)
      when mode in [:bookkeeping, :future, :requested, :force] do
    item =
      Repo.preload(item, [:generated_feed, article: [:extraction, :digests]], force: true)

    settings = Operations.get_settings()
    definition = step_definition(step, settings)

    case Repo.get_by(GeneratedFeedItemStep,
           generated_feed_item_id: item.id,
           step_type: step.step_type
         ) do
      nil ->
        attrs =
          definition
          |> Map.merge(%{
            generated_feed_item_id: item.id,
            pipeline_step_id: step.id,
            position: step.position
          })
          |> Map.merge(initial_item_step_state(item.article, step.step_type, definition, mode))

        %GeneratedFeedItemStep{}
        |> GeneratedFeedItemStep.changeset(attrs)
        |> Repo.insert()

      %GeneratedFeedItemStep{} = item_step ->
        ensure_existing_item_step(item_step, item.article, step, definition, mode)
    end
  end

  defp ensure_existing_item_step(item_step, article, step, definition, mode) do
    item_step_definition = Map.merge(definition, %{step_type: step.step_type})

    reusable =
      if mode == :force, do: :missing, else: reusable_artifact(article, item_step_definition)

    case reusable do
      {:ok, artifact_attrs} ->
        attrs =
          definition
          |> Map.merge(artifact_attrs)
          |> maybe_mark_reused_success(item_step, artifact_attrs)
          |> Map.merge(%{pipeline_step_id: step.id, position: step.position})

        item_step
        |> GeneratedFeedItemStep.changeset(attrs)
        |> Repo.update()

      :missing when item_step.status == "succeeded" and mode == :requested ->
        relink_definition(item_step, step)

      :missing when mode in [:requested, :force] ->
        status =
          if mode == :force,
            do: forced_status(article, step.step_type),
            else: requested_status(article, step.step_type)

        attrs =
          definition
          |> Map.merge(%{
            pipeline_step_id: step.id,
            position: step.position,
            status: status,
            reused_artifact: false,
            error_message: nil,
            latest_attempt_id: nil,
            started_at: nil,
            finished_at: nil,
            article_extraction_id: nil,
            article_digest_id: nil
          })

        item_step
        |> GeneratedFeedItemStep.changeset(attrs)
        |> Repo.update()

      :missing ->
        relink_definition(item_step, step)
    end
  end

  # A surviving item-step row (its definition was removed and re-added) keeps
  # its history but must point at the current definition and position.
  defp relink_definition(%GeneratedFeedItemStep{} = item_step, %PipelineStep{} = step) do
    if item_step.pipeline_step_id == step.id and item_step.position == step.position do
      {:ok, item_step}
    else
      item_step
      |> GeneratedFeedItemStep.changeset(%{pipeline_step_id: step.id, position: step.position})
      |> Repo.update()
    end
  end

  defp maybe_mark_reused_success(attrs, item_step, artifact_attrs) do
    same_artifact? =
      item_step.status == "succeeded" and
        item_step.article_extraction_id == Map.get(artifact_attrs, :article_extraction_id) and
        item_step.article_digest_id == Map.get(artifact_attrs, :article_digest_id)

    if same_artifact?, do: attrs, else: Map.merge(attrs, success_state(true))
  end

  def advance_item(item_id, opts \\ []) when is_integer(item_id) do
    item =
      GeneratedFeedItem
      |> Repo.get!(item_id)
      |> Repo.preload([:generated_feed, article: [:extraction, :digests]])

    item.id
    |> list_item_steps()
    |> Enum.reduce_while({:ok, []}, fn item_step, {:ok, attempts} ->
      case advance_item_step(item, item_step, opts) do
        {:continue, _item_step} -> {:cont, {:ok, attempts}}
        {:halt, nil} -> {:halt, {:ok, attempts}}
        {:halt, %PipelineStepAttempt{} = attempt} -> {:halt, {:ok, [attempt | attempts]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp advance_item_step(_item, %{status: status} = item_step, _opts)
       when status in ["succeeded", "skipped"] do
    {:continue, item_step}
  end

  defp advance_item_step(_item, %{status: status}, _opts)
       when status in ["not_requested", "queued", "running", "failed", "cancelled"] do
    {:halt, nil}
  end

  defp advance_item_step(item, item_step, opts) do
    artifact =
      if Keyword.get(opts, :force_step_type) == item_step.step_type,
        do: :missing,
        else: reusable_artifact(item.article, item_step)

    case artifact do
      {:ok, artifact_attrs} ->
        item_step = update_item_step!(item_step, Map.merge(artifact_attrs, success_state(true)))
        {:continue, item_step}

      :missing ->
        if prerequisites_ready?(item.article, item_step.step_type) do
          case enqueue_item_step(item, item_step, opts) do
            {:ok, attempt} -> {:halt, attempt}
            {:error, reason} -> {:error, reason}
          end
        else
          update_item_step!(item_step, %{status: "blocked", error_message: nil})
          {:halt, nil}
        end
    end
  end

  @doc """
  Adds a step to a feed's chain. Accepts a step type (`"digestion"`) or the
  legacy attrs map with an `implementation_key`. Position is canonical
  (`Registry.position_for/1`); prerequisites and global requirements are
  validated here, not in the UI.
  """
  def create_step(%GeneratedFeed{} = feed, step_type) when is_binary(step_type) do
    with {:ok, implementation} <- fetch_implementation_for_type(step_type) do
      create_step(feed, %{"implementation_key" => implementation.key})
    end
  end

  def create_step(%GeneratedFeed{} = feed, attrs) when is_map(attrs) do
    implementation_key = attr(attrs, "implementation_key")

    with {:ok, implementation} <- Registry.fetch_step(implementation_key),
         :ok <- ensure_step_absent(feed.id, implementation.step_type),
         :ok <- ensure_step_can_enable(feed.id, implementation.step_type),
         {:ok, config} <- Registry.normalize_step_config(implementation_key, config_attrs(attrs)) do
      %PipelineStep{}
      |> PipelineStep.changeset(%{
        generated_feed_id: feed.id,
        step_type: implementation.step_type,
        implementation_key: implementation.key,
        position: Registry.position_for(implementation.step_type),
        enabled: boolean_attr(attrs, "enabled", true),
        config: config
      })
      |> Repo.insert()
      |> materialize_step_on_ok()
      |> broadcast_on_ok()
    end
  end

  def create_extraction_step(%GeneratedFeed{} = feed), do: create_step(feed, "extraction")
  def create_digest_step(%GeneratedFeed{} = feed), do: create_step(feed, "digestion")

  @doc """
  Updates a step's enabled flag and config. Enabling checks prerequisites and
  requirements; disabling refuses while a dependent step is enabled or the
  feed's rendering settings depend on this step.
  """
  def update_step(%PipelineStep{} = step, attrs) do
    enabled = boolean_attr(attrs, "enabled", step.enabled)

    under_demand_lock(step, fn ->
      with :ok <- validate_enabled_change(step, enabled),
           {:ok, config} <-
             Registry.normalize_step_config(
               step.implementation_key,
               config_attrs(attrs, step.config)
             ) do
        step
        |> PipelineStep.changeset(%{enabled: enabled, config: config})
        |> Repo.update()
        |> materialize_step_on_ok()
      end
    end)
    |> broadcast_on_ok()
  end

  # Structural changes to a step take the feed/step demand lock exclusively
  # so they cannot race a request that is enrolling new work (audit IMP-06A).
  defp under_demand_lock(%PipelineStep{} = step, fun) do
    Repo.transaction(fn ->
      lock_feed_step!(step.generated_feed_id, step.step_type, :exclusive)

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def materialize_missing_item_steps do
    PipelineStep
    |> order_by([step], asc: step.id)
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn step, {:ok, total} ->
      case materialize_step_items(step) do
        {:ok, count} -> {:cont, {:ok, total + count}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @doc """
  Removes a step definition. Refused while a dependent step exists, the
  feed's rendering depends on it, or it has queued/running work. Item-step
  snapshot rows are left untouched (their `pipeline_step_id` nils out).
  """
  def delete_step(%PipelineStep{} = step) do
    under_demand_lock(step, fn ->
      with :ok <- ensure_no_dependents(step, :any),
           :ok <- ensure_rendering_independent(step),
           :ok <- ensure_no_active_work(step) do
        Repo.delete(step)
      end
    end)
    |> broadcast_on_ok()
  end

  @doc """
  Every feed's chain in canonical order with per-step coverage, the feed's
  held (unpublished) item count, the step types that could still be added,
  and any running batch per step. One entry per feed.
  """
  def pipeline_overview do
    feeds = Newspaper.Publishing.list_generated_feeds()
    held_counts = held_item_counts()
    active_batches = active_batches_by_feed_step()

    Enum.map(feeds, fn feed ->
      steps = Registry.sort_steps(feed.pipeline_steps)
      counts = feed_step_counts(feed.id)
      item_count = Newspaper.Publishing.count_items_for_feed(feed)

      %{
        feed: feed,
        item_count: item_count,
        held: Map.get(held_counts, feed.id, 0),
        steps:
          Enum.map(steps, fn step ->
            %{
              step: step,
              step_type: step.step_type,
              label: Registry.step_label(step.step_type),
              counts: Map.get(counts, step.id, empty_step_counts(item_count)),
              active_batch: Map.get(active_batches, {feed.id, step.step_type})
            }
          end),
        available_step_types: addable_step_types(steps)
      }
    end)
  end

  @doc "Step types not yet in `steps` whose prerequisites are enabled."
  def addable_step_types(steps) do
    present = MapSet.new(steps, & &1.step_type)
    enabled = steps |> Enum.filter(& &1.enabled) |> MapSet.new(& &1.step_type)

    Registry.step_types()
    |> Enum.reject(&MapSet.member?(present, &1))
    |> Enum.filter(fn step_type ->
      Enum.all?(Registry.prerequisites(step_type), &MapSet.member?(enabled, &1))
    end)
  end

  defp empty_step_counts(item_count) do
    %{
      total: item_count,
      ready: 0,
      not_requested: item_count,
      pending: 0,
      blocked: 0,
      queued: 0,
      running: 0,
      failed: 0,
      skipped: 0,
      cancelled: 0
    }
  end

  defp held_item_counts do
    GeneratedFeedItem
    |> where([item], item.publication_status == "processing")
    |> group_by([item], item.generated_feed_id)
    |> select([item], {item.generated_feed_id, count(item.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp active_batches_by_feed_step do
    list_running_feed_batches()
    |> Enum.reduce(%{}, fn batch, acc ->
      case {batch.related["generated_feed_id"], batch.related["step_type"]} do
        {feed_id, step_type} when is_integer(feed_id) and is_binary(step_type) ->
          Map.put_new(acc, {feed_id, step_type}, batch)

        _ ->
          acc
      end
    end)
  end

  defp fetch_implementation_for_type(step_type) do
    case Registry.fetch_implementation_for_type(step_type) do
      {:ok, implementation} -> {:ok, implementation}
      :error -> {:error, {:unknown_step_type, step_type}}
    end
  end

  defp ensure_step_absent(feed_id, step_type) do
    if Repo.exists?(
         from step in PipelineStep,
           where: step.generated_feed_id == ^feed_id and step.step_type == ^step_type
       ),
       do: {:error, :step_exists},
       else: :ok
  end

  defp ensure_step_can_enable(feed_id, step_type) do
    enabled_types =
      feed_id |> list_enabled_steps() |> MapSet.new(& &1.step_type)

    missing =
      step_type
      |> Registry.prerequisites()
      |> Enum.reject(&MapSet.member?(enabled_types, &1))

    cond do
      missing != [] -> {:error, prerequisite_error(hd(missing))}
      true -> ensure_requirements(step_type)
    end
  end

  defp ensure_requirements(step_type) do
    step_type
    |> Registry.requirements()
    |> Enum.reduce_while(:ok, fn
      :ollama_model, :ok ->
        case Operations.get_settings().ollama_model do
          model when is_binary(model) and model != "" -> {:cont, :ok}
          _model -> {:halt, {:error, :ollama_model_not_configured}}
        end

      _requirement, :ok ->
        {:cont, :ok}
    end)
  end

  defp validate_enabled_change(%PipelineStep{enabled: enabled}, enabled), do: :ok

  defp validate_enabled_change(%PipelineStep{} = step, true),
    do: ensure_step_can_enable(step.generated_feed_id, step.step_type)

  defp validate_enabled_change(%PipelineStep{} = step, false) do
    with :ok <- ensure_no_dependents(step, :enabled) do
      ensure_rendering_independent(step)
    end
  end

  defp ensure_no_dependents(%PipelineStep{} = step, which) do
    dependent_types = Registry.dependents(step.step_type)

    query =
      from other in PipelineStep,
        where:
          other.generated_feed_id == ^step.generated_feed_id and
            other.step_type in ^dependent_types

    query = if which == :enabled, do: where(query, [other], other.enabled == true), else: query

    case Repo.all(query) do
      [] -> :ok
      [dependent | _rest] -> {:error, dependents_error(dependent.step_type)}
    end
  end

  defp ensure_rendering_independent(%PipelineStep{} = step) do
    feed = Newspaper.Publishing.get_generated_feed!(step.generated_feed_id)

    if step.step_type in Newspaper.Publishing.rendering_step_dependencies(feed),
      do: {:error, rendering_error(step.step_type)},
      else: :ok
  end

  # Active demand is judged by this definition's own item steps (which may be
  # served by another feed's attempt) and by an active batch for the
  # feed/step, not by attempts that happen to name this definition
  # (audit IMP-07).
  defp ensure_no_active_work(%PipelineStep{} = step) do
    # "blocked" is not counted: every bookkeeping row for a step whose
    # prerequisite has not run is blocked, so it cannot mean requested work.
    live_item_steps? =
      Repo.exists?(
        from item_step in GeneratedFeedItemStep,
          where:
            item_step.pipeline_step_id == ^step.id and
              item_step.status in ["pending", "queued", "running"]
      )

    active_batch? =
      Map.has_key?(active_batches_by_feed_step(), {step.generated_feed_id, step.step_type})

    if live_item_steps? or active_batch?,
      do: {:error, :step_has_active_work},
      else: :ok
  end

  defp prerequisite_error("extraction"), do: :extraction_step_required
  defp prerequisite_error(step_type), do: {:prerequisite_required, step_type}

  defp dependents_error("digestion"), do: :digestion_requires_extraction
  defp dependents_error(step_type), do: {:dependent_step_enabled, step_type}

  defp rendering_error("extraction"), do: :rendering_requires_extraction
  defp rendering_error("digestion"), do: :digest_rendering_requires_digestion
  defp rendering_error(step_type), do: {:rendering_depends_on_step, step_type}

  def list_attempts_for_article(article_id) do
    PipelineStepAttempt
    |> where([attempt], attempt.article_id == ^article_id)
    |> order_by([attempt], desc: attempt.inserted_at)
    |> preload([:pipeline_step, :generated_feed_item])
    |> Repo.all()
  end

  @doc """
  Every execution that served a batch: those it created and those it joined
  through a shared article, from the immutable batch/attempt lineage
  (audit IMP-16).
  """
  def list_attempts_for_batch(batch_run_id) when is_integer(batch_run_id) do
    PipelineStepAttempt
    |> filter_attempt_batch(batch_run_id)
    |> order_by([attempt], asc: attempt.id)
    |> preload([:pipeline_step, :article, generated_feed_item: :generated_feed])
    |> Repo.all()
  end

  def list_processing_attempts(statuses, opts \\ []) when is_list(statuses) do
    limit = Keyword.get(opts, :limit, 100)
    order = Keyword.get(opts, :order, :asc)

    PipelineStepAttempt
    |> where([attempt], attempt.status in ^statuses)
    |> filter_processing_attempts(opts)
    |> order_processing_attempts(order)
    |> limit(^limit)
    |> preload_processing_attempts(Keyword.get(opts, :preload, :full))
    |> Repo.all()
  end

  # `:light` loads only what a queue row needs (no rendered items, no runs);
  # feed titles then come from `feed_titles_for_attempts/1` (audit IMP-18).
  defp preload_processing_attempts(query, :light), do: preload(query, [:article, :batch_run])

  defp preload_processing_attempts(query, _full) do
    preload(query, [
      :article,
      :pipeline_step,
      :batch_run,
      :runs,
      generated_feed_item: :generated_feed,
      generated_feed_item_step: [generated_feed_item: :generated_feed],
      affected_item_steps: [generated_feed_item: :generated_feed]
    ])
  end

  # The website of an article's extraction URL, computed in SQL with the
  # same rules as `Content.site_host/1` (lower-case, no leading "www.").
  defmacrop sql_site_host(article) do
    quote do
      fragment(
        "regexp_replace(lower(coalesce(?, ?)), '^https{0,1}://(www\\.){0,1}([^/:#]+).*$', '\\2')",
        unquote(article).resolved_url,
        unquote(article).canonical_url
      )
    end
  end

  @doc "Queued extraction executions per website, aggregated in SQL."
  def queued_extraction_host_counts do
    PipelineStepAttempt
    |> join(:inner, [attempt], article in Article, on: article.id == attempt.article_id)
    |> where([attempt], attempt.step_type == "extraction" and attempt.status == "queued")
    |> group_by([_attempt, article], sql_site_host(article))
    |> select([attempt, article], {sql_site_host(article), count(attempt.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The next `per_host` queued extraction executions of **every** website, in
  dispatch order (foreground before bulk, then arrival), so no website's
  queue is hidden behind another's backlog (audit IMP-15).
  """
  def list_queued_extraction_by_host(per_host, opts \\ []) when is_integer(per_host) do
    ranked =
      PipelineStepAttempt
      |> join(:inner, [attempt], article in Article, on: article.id == attempt.article_id)
      |> where([attempt], attempt.step_type == "extraction" and attempt.status == "queued")
      |> select([attempt, article], %{
        id: attempt.id,
        rank:
          fragment(
            "row_number() OVER (PARTITION BY ? ORDER BY (CASE WHEN ? IS NULL THEN 0 ELSE 1 END) ASC, ? ASC, ? ASC)",
            sql_site_host(article),
            attempt.batch_run_id,
            attempt.inserted_at,
            attempt.id
          )
      })

    ids =
      from ranked in subquery(ranked), where: ranked.rank <= ^per_host, select: ranked.id

    PipelineStepAttempt
    |> where([attempt], attempt.id in subquery(ids))
    |> order_processing_attempts(:priority)
    |> preload_processing_attempts(Keyword.get(opts, :preload, :full))
    |> Repo.all()
  end

  @doc "Waiting item steps aggregated by step and feed before any limit (audit IMP-15)."
  def waiting_item_step_groups(limit \\ 100) do
    GeneratedFeedItemStep
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> join(:inner, [_item_step, item], feed in GeneratedFeed,
      on: feed.id == item.generated_feed_id
    )
    |> where([item_step], item_step.status in ["blocked", "pending"])
    |> group_by([item_step, _item, feed], [item_step.step_type, feed.id, feed.title])
    |> select([item_step, _item, feed], %{
      step_type: item_step.step_type,
      feed_id: feed.id,
      feed_title: feed.title,
      count: count(item_step.id)
    })
    |> order_by([item_step, _item, feed], desc: count(item_step.id), asc: feed.title)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Output feed titles per attempt from durable participation, for lists that
  load attempts without their rendered items.
  """
  def feed_titles_for_attempts([]), do: %{}

  def feed_titles_for_attempts(attempt_ids) when is_list(attempt_ids) do
    PipelineItemStepAttempt
    |> join(:inner, [participation], item_step in GeneratedFeedItemStep,
      on: item_step.id == participation.generated_feed_item_step_id
    )
    |> join(:inner, [_participation, item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> join(:inner, [_participation, _item_step, item], feed in GeneratedFeed,
      on: feed.id == item.generated_feed_id
    )
    |> where([participation], participation.pipeline_step_attempt_id in ^attempt_ids)
    |> select(
      [participation, _item_step, _item, feed],
      {participation.pipeline_step_attempt_id, feed.title}
    )
    |> distinct(true)
    |> Repo.all()
    |> Enum.group_by(fn {id, _title} -> id end, fn {_id, title} -> title end)
    |> Map.new(fn {id, titles} -> {id, Enum.sort(titles)} end)
  end

  @doc "True when every website with queued extraction work is in backoff."
  def all_queued_hosts_in_backoff?(now \\ DateTime.utc_now(:second)) do
    hosts = queued_extraction_host_counts() |> Map.keys() |> MapSet.new()

    backoff_hosts =
      now |> Content.list_active_site_backoffs() |> Enum.map(& &1.site_host) |> MapSet.new()

    MapSet.size(hosts) > 0 and MapSet.subset?(hosts, backoff_hosts)
  end

  def processing_attempt_counts(opts \\ []) do
    PipelineStepAttempt
    |> filter_processing_attempts(opts)
    |> group_by([attempt], [attempt.step_type, attempt.status])
    |> select([attempt], {attempt.step_type, attempt.status, count(attempt.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {step_type, status, count}, counts ->
      Map.update(counts, step_type, %{status => count}, &Map.put(&1, status, count))
    end)
  end

  def list_waiting_item_steps(opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    GeneratedFeedItemStep
    |> where([item_step], item_step.status in ["blocked", "pending"])
    |> filter_waiting_item_steps(opts)
    |> order_by([item_step], asc: item_step.inserted_at, asc: item_step.id)
    |> limit(^limit)
    |> preload([:pipeline_step, generated_feed_item: [:generated_feed, :article]])
    |> Repo.all()
  end

  def waiting_item_step_counts(opts \\ []) do
    GeneratedFeedItemStep
    |> where([item_step], item_step.status in ["blocked", "pending"])
    |> filter_waiting_item_steps(opts)
    |> group_by([item_step], [item_step.step_type, item_step.status])
    |> select([item_step], {item_step.step_type, item_step.status, count(item_step.id)})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {step_type, status, count}, counts ->
      Map.update(counts, step_type, %{status => count}, &Map.put(&1, status, count))
    end)
  end

  def list_feed_batches(feed_id, limit \\ 5) when is_integer(feed_id) do
    feed_id = Integer.to_string(feed_id)

    Run
    |> where(
      [run],
      run.run_type == "pipeline_batch" and
        fragment("jsonb_extract_path_text(?, 'generated_feed_id') = ?", run.related, ^feed_id)
    )
    |> order_by([run], desc: run.started_at, desc: run.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp filter_processing_attempts(query, opts) do
    query
    |> filter_attempt_step_type(Keyword.get(opts, :step_type))
    |> filter_attempt_article(Keyword.get(opts, :article_id))
    |> filter_attempt_batch(Keyword.get(opts, :batch_run_id))
    |> filter_attempt_feed(Keyword.get(opts, :generated_feed_id))
  end

  defp filter_attempt_step_type(query, step_type)
       when step_type in ["extraction", "digestion"] do
    where(query, [attempt], attempt.step_type == ^step_type)
  end

  defp filter_attempt_step_type(query, _step_type), do: query

  defp filter_attempt_article(query, article_id) when is_integer(article_id) do
    where(query, [attempt], attempt.article_id == ^article_id)
  end

  defp filter_attempt_article(query, _article_id), do: query

  defp filter_attempt_batch(query, batch_run_id) when is_integer(batch_run_id) do
    lineage =
      from lineage in PipelineBatchAttempt,
        where: lineage.batch_run_id == ^batch_run_id,
        select: lineage.pipeline_step_attempt_id

    where(
      query,
      [attempt],
      attempt.batch_run_id == ^batch_run_id or attempt.id in subquery(lineage)
    )
  end

  defp filter_attempt_batch(query, _batch_run_id), do: query

  # Feed-scoped history reads durable participation, so an execution a feed
  # consumed stays in its history after the item step moves on to a retry
  # (audit IMP-16).
  defp filter_attempt_feed(query, generated_feed_id) when is_integer(generated_feed_id) do
    feed_item_ids =
      from item in GeneratedFeedItem,
        where: item.generated_feed_id == ^generated_feed_id,
        select: item.id

    participating_attempt_ids =
      from participation in PipelineItemStepAttempt,
        join: item_step in GeneratedFeedItemStep,
        on: item_step.id == participation.generated_feed_item_step_id,
        join: item in GeneratedFeedItem,
        on: item.id == item_step.generated_feed_item_id,
        where: item.generated_feed_id == ^generated_feed_id,
        select: participation.pipeline_step_attempt_id

    where(
      query,
      [attempt],
      attempt.generated_feed_item_id in subquery(feed_item_ids) or
        attempt.id in subquery(participating_attempt_ids)
    )
  end

  defp filter_attempt_feed(query, _generated_feed_id), do: query

  defp filter_waiting_item_steps(query, opts) do
    query
    |> filter_waiting_step_type(Keyword.get(opts, :step_type))
    |> filter_waiting_article(Keyword.get(opts, :article_id))
    |> filter_waiting_feed(Keyword.get(opts, :generated_feed_id))
  end

  defp filter_waiting_step_type(query, step_type)
       when step_type in ["extraction", "digestion"] do
    where(query, [item_step], item_step.step_type == ^step_type)
  end

  defp filter_waiting_step_type(query, _step_type), do: query

  defp filter_waiting_article(query, article_id) when is_integer(article_id) do
    query
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> where([_item_step, item], item.article_id == ^article_id)
  end

  defp filter_waiting_article(query, _article_id), do: query

  defp filter_waiting_feed(query, generated_feed_id) when is_integer(generated_feed_id) do
    query
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> where([_item_step, item], item.generated_feed_id == ^generated_feed_id)
  end

  defp filter_waiting_feed(query, _generated_feed_id), do: query

  # Dispatch order: the foreground class before the bulk class, then arrival
  # within the class. Batch identity never orders work (audit IMP-15).
  defp order_processing_attempts(query, :priority) do
    order_by(query, [attempt],
      asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", attempt.batch_run_id),
      asc: attempt.inserted_at,
      asc: attempt.id
    )
  end

  defp order_processing_attempts(query, :desc) do
    order_by(query, [attempt],
      desc_nulls_last: attempt.finished_at,
      desc: attempt.inserted_at,
      desc: attempt.id
    )
  end

  defp order_processing_attempts(query, _order) do
    order_by(query, [attempt], asc: attempt.inserted_at, asc: attempt.id)
  end

  @throughput_window_minutes 60
  @min_rate_samples 3

  @doc """
  Executions of `step_type` completed per minute over the trailing window.
  The rate is nil until at least #{@min_rate_samples} completions exist.
  """
  def stage_throughput(step_type, opts \\ []) when is_binary(step_type) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    window_start = DateTime.add(now, -@throughput_window_minutes * 60, :second)

    completed =
      PipelineStepAttempt
      |> where([attempt], attempt.step_type == ^step_type)
      |> completed_in_window(window_start, now)
      |> Repo.aggregate(:count, :id)

    %{
      completed: completed,
      window_minutes: @throughput_window_minutes,
      per_minute: rate_per_minute(completed)
    }
  end

  @doc """
  Progress for a `pipeline_batch` run: done/total/remaining from the run's
  summary, rate from its attempts completed in the trailing window, and an
  estimate only when it is defensible. `eta_reason` explains an absent ETA.
  """
  def batch_progress(%Run{} = batch, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:second))
    counts = batch.summary_counts || %{}

    total =
      if is_nil(counts["total"]), do: nil, else: counts["total"] - count(counts, "cancelled")

    done = count(counts, "succeeded") + count(counts, "failed") + count(counts, "skipped")
    remaining = count(counts, "queued") + count(counts, "running")
    step_type = batch.related["step_type"] || "extraction"
    window_start = DateTime.add(now, -@throughput_window_minutes * 60, :second)

    completed_recently =
      PipelineStepAttempt
      |> where([attempt], attempt.batch_run_id == ^batch.id)
      |> completed_in_window(window_start, now)
      |> Repo.aggregate(:count, :id)

    per_minute = rate_per_minute(completed_recently)

    eta_reason =
      cond do
        is_nil(total) -> :not_started
        remaining == 0 -> :complete
        step_type == "digestion" and Operations.get_settings().digestion_paused -> :paused
        step_type == "extraction" and all_queued_hosts_in_backoff?(batch.id, now) -> :site_backoff
        is_nil(per_minute) -> :insufficient_samples
        true -> nil
      end

    eta_seconds =
      if is_nil(eta_reason), do: round(remaining / per_minute * 60), else: nil

    %{
      done: done,
      total: total,
      remaining: remaining,
      per_minute: per_minute,
      eta_seconds: eta_seconds,
      eta_reason: eta_reason
    }
  end

  defp completed_in_window(query, window_start, now) do
    query
    |> where([attempt], attempt.status in ["succeeded", "failed", "skipped"])
    |> where([attempt], attempt.failure_kind != "cancelled" or is_nil(attempt.failure_kind))
    |> where([attempt], attempt.finished_at > ^window_start and attempt.finished_at <= ^now)
  end

  defp rate_per_minute(completed) when completed < @min_rate_samples, do: nil
  defp rate_per_minute(completed), do: completed / @throughput_window_minutes

  defp count(counts, key), do: Map.get(counts || %{}, key, 0)

  defp all_queued_hosts_in_backoff?(batch_run_id, now) do
    hosts =
      PipelineStepAttempt
      |> join(:inner, [attempt], article in Article, on: article.id == attempt.article_id)
      |> where([attempt], attempt.batch_run_id == ^batch_run_id and attempt.status == "queued")
      |> select([_attempt, article], coalesce(article.resolved_url, article.canonical_url))
      |> Repo.all()
      |> Enum.map(&Content.site_host/1)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    backoff_hosts =
      now |> Content.list_active_site_backoffs() |> Enum.map(& &1.site_host) |> MapSet.new()

    MapSet.size(hosts) > 0 and MapSet.subset?(hosts, backoff_hosts)
  end

  @doc "Every pipeline batch across feeds, running first, then newest."
  def list_batches(limit \\ 100) do
    Run
    |> where([run], run.run_type == "pipeline_batch")
    |> order_by([run],
      asc: fragment("CASE WHEN ? = 'running' THEN 0 ELSE 1 END", run.status),
      desc: run.started_at,
      desc: run.id
    )
    |> limit(^limit)
    |> Repo.all()
  end

  def feed_processing_counts(feed_id) when is_integer(feed_id) do
    case Enum.find(list_steps(feed_id), &(&1.step_type == "extraction")) do
      nil ->
        items =
          Repo.aggregate(
            from(item in GeneratedFeedItem, where: item.generated_feed_id == ^feed_id),
            :count,
            :id
          )

        %{items: items, extracted: 0, unavailable: 0, not_requested: items}

      step ->
        counts = Map.fetch!(feed_step_counts(feed_id), step.id)

        %{
          items: counts.total,
          extracted: counts.ready,
          unavailable: counts.failed + counts.skipped,
          not_requested: counts.not_requested + counts.blocked
        }
    end
  end

  def list_queued_attempts(step_type \\ nil) do
    PipelineStepAttempt
    |> where([attempt], attempt.status == "queued")
    |> then(fn query ->
      if is_binary(step_type),
        do: where(query, [attempt], attempt.step_type == ^step_type),
        else: query
    end)
    |> order_processing_attempts(:priority)
    |> Repo.all()
  end

  @doc """
  Restart recovery for attempts left `running`. An attempt whose only
  consumers belonged to a cancelled batch is cancelled; one that any live
  demand still points at (another feed's batch, a foreground request) is
  re-queued for that demand (audit IMP-05). Returns the number re-queued.
  """
  def requeue_interrupted_attempts(step_type \\ nil) do
    now = DateTime.utc_now(:second)

    interrupted =
      PipelineStepAttempt
      |> where([attempt], attempt.status == "running")
      |> then(fn query ->
        if is_binary(step_type),
          do: where(query, [attempt], attempt.step_type == ^step_type),
          else: query
      end)
      |> Repo.all()

    {cancelled_ids, requeued_ids} =
      Enum.reduce(interrupted, {[], []}, fn attempt, {cancelled, requeued} ->
        {_withdrawn, live} = partition_withdrawn_consumers(attempt.id, @live_item_statuses)

        if live == [] do
          {[attempt.id | cancelled], requeued}
        else
          live_ids = Enum.map(live, & &1.id)

          GeneratedFeedItemStep
          |> where([item_step], item_step.id in ^live_ids)
          |> Repo.update_all(
            set: [
              status: "queued",
              started_at: nil,
              finished_at: nil,
              error_message: "Application restarted while attempt was running",
              updated_at: now
            ]
          )

          {cancelled, [attempt.id | requeued]}
        end
      end)

    if cancelled_ids != [] do
      PipelineStepAttempt
      |> where([attempt], attempt.id in ^cancelled_ids)
      |> Repo.update_all(
        set: [
          status: "skipped",
          failure_kind: "cancelled",
          retryable: false,
          finished_at: now,
          error_message: "Cancelled by operator before the restart",
          updated_at: now
        ]
      )

      close_interrupted_runs(cancelled_ids)
    end

    if requeued_ids != [] do
      PipelineStepAttempt
      |> where([attempt], attempt.id in ^requeued_ids)
      |> Repo.update_all(
        set: [
          status: "queued",
          started_at: nil,
          finished_at: nil,
          error_message: "Application restarted while attempt was running",
          updated_at: now
        ]
      )

      close_interrupted_runs(requeued_ids)
    end

    refresh_active_batch_runs()
    length(requeued_ids)
  end

  defp close_interrupted_runs(interrupted_ids) do
    Run
    |> where(
      [run],
      run.run_type == "pipeline_step" and run.status == "running" and
        run.pipeline_step_attempt_id in ^interrupted_ids
    )
    |> Repo.update_all(
      set: [
        status: "failed",
        finished_at: DateTime.utc_now(:second),
        error_summary: "Application restarted while run was in progress"
      ]
    )

    :ok
  end

  def get_attempt!(id) do
    PipelineStepAttempt
    |> Repo.get!(id)
    |> Repo.preload([
      :pipeline_step,
      :generated_feed_item_step,
      article: [:extraction, :digests],
      generated_feed_item: :generated_feed
    ])
  end

  @doc """
  Retries an attempt for the items that still consume it. Cancelled item
  steps are never retried; the new attempt stays with the originating batch
  only while that batch is live, otherwise it becomes foreground work
  (audit IMP-05).
  """
  def retry_attempt(attempt_id, opts \\ []) do
    attempt = get_attempt!(attempt_id)
    request_metadata = retry_request_metadata(opts)

    batch_run_id =
      case Keyword.fetch(opts, :batch_run_id) do
        {:ok, id} -> id
        :error -> if batch_running?(attempt.batch_run_id), do: attempt.batch_run_id, else: nil
      end

    attempt
    |> retry_items(Keyword.get(opts, :item_step_ids))
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, attempts} ->
      case request_item_step(item, attempt.step_type,
             force: true,
             batch_run_id: batch_run_id,
             request_metadata: request_metadata
           ) do
        {:ok, item_attempts} -> {:cont, {:ok, item_attempts ++ attempts}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, attempts} ->
        case attempts |> Enum.uniq_by(& &1.id) |> List.first() do
          %PipelineStepAttempt{} = retry_attempt -> {:ok, retry_attempt}
          nil -> {:error, :step_not_available}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  def schedule_automatic_retry(%PipelineStepAttempt{} = attempt) do
    attempt = Repo.get!(PipelineStepAttempt, attempt.id)

    if automatic_rate_limit_retry?(attempt) do
      {_withdrawn, live} = partition_withdrawn_consumers(attempt.id, ["failed"])

      if live == [] do
        settle_failed_members(attempt.id)
        {:ok, nil}
      else
        live_ids = Enum.map(live, & &1.id)

        # Only a batch with an open member in a running run is current
        # demand; a settled historical membership never reacquires work
        # (audit IMP-02).
        batch_run_id = open_running_batch_id(live_ids)

        retry_attempt(attempt.id,
          origin: "automatic_rate_limit",
          retry_number: rate_limit_failure_streak(attempt),
          retry_limit: @automatic_rate_limit_retries,
          item_step_ids: live_ids,
          batch_run_id: batch_run_id
        )
      end
    else
      settle_failed_members(attempt.id)
      {:ok, nil}
    end
  end

  defp open_running_batch_id(item_step_ids) do
    PipelineBatchMember
    |> join(:inner, [member], batch in Run, on: batch.id == member.batch_run_id)
    |> where(
      [member, batch],
      member.generated_feed_item_step_id in ^item_step_ids and is_nil(member.outcome) and
        batch.status == "running" and not fragment("? \\? 'cancelled_at'", batch.related)
    )
    |> select([member], member.batch_run_id)
    |> limit(1)
    |> Repo.one()
  end

  # Once no further automatic retry is permitted, the failed members of the
  # attempt's consumers become terminal (audit IMP-02).
  defp settle_failed_members(attempt_id) do
    item_step_ids =
      GeneratedFeedItemStep
      |> where(
        [item_step],
        item_step.latest_attempt_id == ^attempt_id and item_step.status == "failed"
      )
      |> select([item_step], item_step.id)
      |> Repo.all()

    if item_step_ids != [] do
      PipelineBatchMember
      |> where(
        [member],
        member.generated_feed_item_step_id in ^item_step_ids and is_nil(member.outcome)
      )
      |> Repo.update_all(set: [outcome: "failed", outcome_at: DateTime.utc_now(:second)])

      refresh_batches_for_item_steps(item_step_ids)
    end

    :ok
  end

  def requeue_stranded_rate_limits(step_type \\ "extraction") do
    step_type
    |> automatic_retry_candidates()
    |> Enum.reduce(0, fn attempt, count ->
      case schedule_automatic_retry(attempt) do
        {:ok, %PipelineStepAttempt{}} -> count + 1
        {:ok, nil} -> count
        {:error, _reason} -> count
      end
    end)
  end

  @doc """
  Claims a queued attempt for execution. Only a `queued` row can be claimed;
  a cancelled or already-claimed attempt returns `{:error, :not_queued}`.
  """
  def mark_attempt_running(%PipelineStepAttempt{} = attempt) do
    now = DateTime.utc_now(:second)

    claimed =
      PipelineStepAttempt
      |> where([candidate], candidate.id == ^attempt.id and candidate.status == "queued")
      |> Repo.update_all(set: [status: "running", started_at: now, updated_at: now])

    case claimed do
      {1, _rows} ->
        result = {:ok, %{attempt | status: "running", started_at: now}}
        update_attempt_item_steps(attempt.id, %{status: "running", started_at: now})
        Newspaper.Events.broadcast_data_changed(:processing_changed)
        refresh_attempt_batch(result)

      {0, _rows} ->
        {:error, :not_queued}
    end
  end

  def finish_attempt(%PipelineStepAttempt{} = attempt, status, attrs \\ %{})
      when status in ["succeeded", "failed", "skipped"] do
    now = DateTime.utc_now(:second)

    attrs =
      attrs
      |> Map.put(:status, status)
      |> Map.put(:finished_at, now)

    result =
      attempt
      |> PipelineStepAttempt.changeset(attrs)
      |> Repo.update()
      |> broadcast_on_ok()

    if match?({:ok, _attempt}, result) do
      update_attempt_item_steps(attempt.id, %{
        status: status,
        error_message: Map.get(attrs, :error_message),
        finished_at: now
      })
    end

    refresh_attempt_batch(result)
  end

  def fail_dispatched_attempt(attempt_id, failure_kind, message, retryable \\ true)
      when is_integer(attempt_id) do
    attempt = get_attempt!(attempt_id)

    if attempt.status in ["queued", "running"] do
      if attempt.step_type == "extraction" do
        Content.set_extraction_status(attempt.article, "failed")
      end

      result =
        finish_attempt(attempt, "failed", %{
          failure_kind: failure_kind,
          retryable: retryable,
          error_message: message
        })

      Operations.fail_running_pipeline_step_runs(attempt.id, message)

      Operations.create_failure(%{
        failure_type: "pipeline_step_#{failure_kind}",
        message: message,
        retryable: retryable,
        related: %{
          "pipeline_step_attempt_id" => attempt.id,
          "pipeline_step_id" => attempt.pipeline_step_id,
          "article_id" => attempt.article_id
        }
      })

      result
    else
      {:ok, attempt}
    end
  end

  def attach_artifact(%PipelineStepAttempt{} = attempt, %ArticleExtraction{} = extraction) do
    reactivate_skipped_article_steps(attempt.article_id, "digestion")

    update_attempt_item_steps(attempt.id, %{
      status: "succeeded",
      article_extraction_id: extraction.id,
      article_digest_id: nil,
      reused_artifact: false,
      error_message: nil,
      finished_at: DateTime.utc_now(:second)
    })

    advance_article_items(attempt.article_id)
  end

  def attach_artifact(%PipelineStepAttempt{} = attempt, %ArticleDigest{} = digest) do
    update_attempt_item_steps(attempt.id, %{
      status: "succeeded",
      article_extraction_id: nil,
      article_digest_id: digest.id,
      reused_artifact: false,
      error_message: nil,
      finished_at: DateTime.utc_now(:second)
    })

    advance_article_items(attempt.article_id)
  end

  def skip_article_steps(article_id, step_type, reason)
      when is_integer(article_id) and is_binary(step_type) and is_binary(reason) do
    now = DateTime.utc_now(:second)

    GeneratedFeedItemStep
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> where(
      [item_step, item],
      item.article_id == ^article_id and item_step.step_type == ^step_type and
        item_step.status in ["not_requested", "pending", "blocked", "failed"]
    )
    |> Repo.update_all(
      set: [
        status: "skipped",
        latest_attempt_id: nil,
        article_extraction_id: nil,
        article_digest_id: nil,
        reused_artifact: false,
        error_message: reason,
        started_at: nil,
        finished_at: now,
        updated_at: now
      ]
    )

    Newspaper.Events.broadcast_data_changed(:processing_changed)
    :ok
  end

  def refresh_batch_run(batch_run_id, items_considered \\ nil)

  def refresh_batch_run(nil, _items_considered), do: {:ok, nil}

  def refresh_batch_run(batch_run_id, _items_considered) when is_integer(batch_run_id) do
    batch = Operations.get_run!(batch_run_id)
    cancelled? = batch_cancelled?(batch)
    counts = batch_member_counts(batch_run_id, cancelled?)
    total = Enum.sum(Map.values(counts))
    summary = Map.put(counts, "total", total)
    active = counts["queued"] + counts["running"]

    cond do
      batch.run_type != "pipeline_batch" ->
        {:ok, batch}

      active > 0 and is_nil(batch.finished_at) ->
        Operations.update_run(batch, %{status: "running", summary_counts: summary})

      is_nil(batch.finished_at) ->
        status =
          cond do
            cancelled? -> "cancelled"
            counts["failed"] > 0 -> "failed"
            true -> "succeeded"
          end

        settle_members!(batch_run_id)
        Operations.finish_run(batch, status, %{summary_counts: summary})

      true ->
        # A finished batch is history: later work on the same items belongs
        # to whoever requested it and never reopens this run.
        {:ok, batch}
    end
  end

  # When a batch finishes, every still-open member takes its item step's
  # terminal state as its outcome so later independent work cannot alter
  # this batch's record.
  defp settle_members!(batch_run_id) do
    now = DateTime.utc_now(:second)

    for status <- @terminal_item_statuses do
      PipelineBatchMember
      |> join(:inner, [member], item_step in GeneratedFeedItemStep,
        on: item_step.id == member.generated_feed_item_step_id
      )
      |> where(
        [member, item_step],
        member.batch_run_id == ^batch_run_id and is_nil(member.outcome) and
          item_step.status == ^status
      )
      |> Repo.update_all(set: [outcome: status, outcome_at: now, updated_at: now])
    end

    :ok
  end

  # Counts by member outcome; active members report their item step's state.
  # Batches created before membership existed fall back to their attempts.
  defp batch_member_counts(batch_run_id, cancelled?) do
    rows =
      PipelineBatchMember
      |> join(:inner, [member], item_step in GeneratedFeedItemStep,
        on: item_step.id == member.generated_feed_item_step_id
      )
      |> join(:left, [_member, item_step], attempt in PipelineStepAttempt,
        on: attempt.id == item_step.latest_attempt_id
      )
      |> where([member], member.batch_run_id == ^batch_run_id)
      |> select(
        [member, item_step, attempt],
        {member.outcome, member.enrolled_at, item_step.status, attempt}
      )
      |> Repo.all()
      |> Enum.map(fn
        # A selected member that enrollment has not reached is pending work,
        # whatever its item step's previous state says (audit IMP-06B).
        {nil, nil, _status, _attempt} ->
          {nil, "queued"}

        # A failed member whose automatic retry is still permitted is not
        # finished: it is waiting for that retry (audit IMP-02). A cancelled
        # batch will not retry, so there it counts as failed.
        {nil, _enrolled_at, "failed", %PipelineStepAttempt{} = attempt} when not cancelled? ->
          if automatic_rate_limit_retry?(attempt), do: {nil, "queued"}, else: {nil, "failed"}

        {outcome, _enrolled_at, status, _attempt} ->
          {outcome, status}
      end)

    base = %{
      "queued" => 0,
      "running" => 0,
      "succeeded" => 0,
      "failed" => 0,
      "skipped" => 0,
      "cancelled" => 0
    }

    Enum.reduce(rows, base, fn {outcome, status}, acc ->
      Map.update!(acc, member_bucket(outcome, status), &(&1 + 1))
    end)
  end

  defp member_bucket(outcome, _status)
       when outcome in ["succeeded", "failed", "skipped", "cancelled"],
       do: outcome

  defp member_bucket(_outcome, status)
       when status in ["succeeded", "failed", "skipped", "cancelled"],
       do: status

  defp member_bucket(_outcome, "running"), do: "running"
  defp member_bucket(_outcome, _status), do: "queued"

  @doc "Records that `item_step_id` belongs to `batch_run_id` (idempotent)."
  def ensure_member(batch_run_id, item_step_id) do
    %PipelineBatchMember{}
    |> PipelineBatchMember.changeset(%{
      batch_run_id: batch_run_id,
      generated_feed_item_step_id: item_step_id
    })
    |> Repo.insert(
      on_conflict: :nothing,
      conflict_target: [:batch_run_id, :generated_feed_item_step_id]
    )
  end

  def change_step(%PipelineStep{} = step, attrs \\ %{}), do: PipelineStep.changeset(step, attrs)

  # Enrolls each open member in turn. A member that cancellation settled in
  # the meantime is skipped, and a cancelled batch stops enrollment on the
  # very next item (audit IMP-06).
  defp enqueue_batch_members(members, batch_run_id, step_type, selection) do
    opts = batch_request_opts(batch_run_id, selection)

    Enum.reduce_while(members, :ok, fn %{item: item, item_step_id: item_step_id}, :ok ->
      cond do
        not member_open?(batch_run_id, item_step_id) ->
          {:cont, :ok}

        true ->
          case request_item_step(item, step_type, opts) do
            {:ok, attempts} ->
              record_member!(batch_run_id, item.id, step_type, attempts)
              {:cont, :ok}

            {:error, :batch_cancelled} ->
              {:halt, :ok}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
      end
    end)
  end

  defp member_open?(batch_run_id, item_step_id) do
    Repo.exists?(
      from member in PipelineBatchMember,
        where:
          member.batch_run_id == ^batch_run_id and
            member.generated_feed_item_step_id == ^item_step_id and is_nil(member.outcome)
    )
  end

  # A member that enrollment resolved without new work records its outcome
  # immediately: satisfied by an existing artifact, or skipped because the item
  # was already terminal (a pre-existing failure is not this batch's failure).
  defp record_member!(batch_run_id, item_id, step_type, attempts) do
    case Repo.get_by(GeneratedFeedItemStep, generated_feed_item_id: item_id, step_type: step_type) do
      nil ->
        :ok

      item_step ->
        {:ok, _member} = ensure_member(batch_run_id, item_step.id)
        mark_enrolled!(batch_run_id, item_step.id)

        outcome =
          cond do
            attempts != [] -> nil
            item_step.status == "succeeded" -> "succeeded"
            item_step.status in @terminal_item_statuses -> "skipped"
            true -> nil
          end

        if outcome do
          PipelineBatchMember
          |> where(
            [member],
            member.batch_run_id == ^batch_run_id and
              member.generated_feed_item_step_id == ^item_step.id and is_nil(member.outcome)
          )
          |> Repo.update_all(set: [outcome: outcome, outcome_at: DateTime.utc_now(:second)])
        end

        :ok
    end
  end

  # Enrollment and recovery both read the durable members that are still open.
  defp batch_enrollment_members(batch) do
    PipelineBatchMember
    |> join(:inner, [member], item_step in GeneratedFeedItemStep,
      on: item_step.id == member.generated_feed_item_step_id
    )
    |> join(:inner, [_member, item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> where([member], member.batch_run_id == ^batch.id and is_nil(member.outcome))
    |> order_by([_member, _item_step, item], asc: item.id)
    |> select([member, _item_step, item], {member.generated_feed_item_step_id, item})
    |> Repo.all()
    |> then(fn rows ->
      items =
        rows
        |> Enum.map(fn {_item_step_id, item} -> item end)
        |> Repo.preload([:generated_feed, article: [:extraction, :digests]])

      rows
      |> Enum.zip(items)
      |> Enum.map(fn {{item_step_id, _item}, item} ->
        %{item_step_id: item_step_id, item: item}
      end)
    end)
  end

  defp create_feed_batch(feed, steps, trigger, step_type, selection) do
    selection = selection_name(selection)

    Operations.start_run(
      "pipeline_batch",
      trigger,
      %{
        "batch_type" => batch_type(step_type, selection),
        "generated_feed_id" => feed.id,
        "generated_feed_title" => feed.title,
        "step_type" => step_type,
        "selection" => selection,
        "members_snapshotted" => true
      },
      %{"pipeline_step_ids" => Enum.map(steps, & &1.id)}
    )
  end

  defp selection_name({:items, _ids}), do: "items"
  defp selection_name(selection) when is_atom(selection), do: Atom.to_string(selection)

  defp feed_batch_context(batch) do
    with feed_id when is_integer(feed_id) <- batch.related["generated_feed_id"],
         step_type when is_binary(step_type) <- batch.related["step_type"],
         selection
         when selection in ["all_existing", "not_requested", "failed", "cancelled", "items"] <-
           Map.get(batch.related, "selection", "all_existing") do
      {:ok, feed_id, step_type, selection}
    else
      _ -> {:error, :invalid_batch_context}
    end
  end

  defp batch_request_opts(batch_run_id, selection) when selection in ["failed", "items"] do
    [
      batch_run_id: batch_run_id,
      request_metadata: %{"retry_origin" => "manual_batch"}
    ]
  end

  defp batch_request_opts(batch_run_id, "cancelled") do
    [
      batch_run_id: batch_run_id,
      revive_downstream: true,
      request_metadata: %{"retry_origin" => "manual_batch"}
    ]
  end

  defp batch_request_opts(batch_run_id, _selection), do: [batch_run_id: batch_run_id]

  defp batch_type(step_type, selection) when selection in ["failed", "items"],
    do: "retry_failed_#{step_type}"

  defp batch_type(step_type, "cancelled"), do: "rerun_cancelled_#{step_type}"
  defp batch_type(step_type, _selection), do: "process_existing_#{step_type}"

  defp format_batch_error(:membership_unrecoverable),
    do:
      "Upgrade could not recover this batch's membership; its outstanding items are still " <>
        "queued or waiting under the pipeline — start the batch again to track them"

  defp format_batch_error(reason) when is_binary(reason), do: reason
  defp format_batch_error(reason), do: inspect(reason)

  defp enqueue_item_step(item, item_step, opts) do
    article = item.article

    case active_attempt(item_step.step_type, article.id) do
      %PipelineStepAttempt{} = attempt ->
        item_step =
          update_item_step!(item_step, %{
            status: attempt.status,
            latest_attempt_id: attempt.id,
            error_message: nil
          })

        record_participation(Keyword.get(opts, :batch_run_id), item_step.id, attempt.id)
        {:ok, %{attempt | generated_feed_item_step: item_step}}

      nil ->
        changeset =
          %PipelineStepAttempt{}
          |> PipelineStepAttempt.changeset(%{
            pipeline_step_id: item_step.pipeline_step_id,
            generated_feed_item_step_id: item_step.id,
            article_id: article.id,
            generated_feed_item_id: item.id,
            implementation_key: item_step.implementation_key,
            step_type: item_step.step_type,
            status: "queued",
            input_snapshot: %{
              "article_id" => article.id,
              "generated_feed_item_id" => item.id,
              "generated_feed_item_step_id" => item_step.id,
              "config" => item_step.config_snapshot,
              "definition_fingerprint" => item_step.definition_fingerprint,
              "request" => Keyword.get(opts, :request_metadata, %{})
            }
          })
          |> put_batch_run(Keyword.get(opts, :batch_run_id))

        changeset
        |> Repo.insert()
        |> case do
          {:ok, attempt} ->
            update_item_step!(item_step, %{
              status: "queued",
              latest_attempt_id: attempt.id,
              reused_artifact: false,
              error_message: nil,
              started_at: nil,
              finished_at: nil
            })

            if item_step.step_type == "extraction" do
              Content.set_extraction_status(article, "queued")
            end

            record_participation(Keyword.get(opts, :batch_run_id), item_step.id, attempt.id)
            dispatch_after_commit(attempt, article)
            Newspaper.Events.broadcast_data_changed(:processing_changed)
            {:ok, attempt}

          {:error, changeset} = error ->
            if active_attempt_conflict?(changeset) do
              attempt = active_attempt(item_step.step_type, article.id)

              update_item_step!(item_step, %{
                status: attempt.status,
                latest_attempt_id: attempt.id,
                error_message: nil
              })

              record_participation(Keyword.get(opts, :batch_run_id), item_step.id, attempt.id)
              {:ok, attempt}
            else
              error
            end
        end
    end
  end

  defp step_definition(%PipelineStep{step_type: "extraction"} = step, _settings) do
    %{
      step_type: step.step_type,
      implementation_key: step.implementation_key,
      config_snapshot: step.config,
      definition_fingerprint: "extraction.site_policy:v1"
    }
  end

  defp step_definition(%PipelineStep{step_type: "digestion"} = step, settings) do
    model = settings.ollama_model || "unconfigured"

    fingerprint =
      [step.implementation_key, model, Digestion.prompt_version(), Digestion.schema_version()]
      |> Enum.join(":")
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      step_type: step.step_type,
      implementation_key: step.implementation_key,
      config_snapshot: %{
        "model" => settings.ollama_model,
        "prompt_version" => Digestion.prompt_version(),
        "schema_version" => Digestion.schema_version()
      },
      definition_fingerprint: fingerprint
    }
  end

  defp initial_item_step_state(article, step_type, definition, :bookkeeping) do
    item_step = Map.merge(definition, %{step_type: step_type})

    case reusable_artifact(article, item_step) do
      {:ok, artifact_attrs} -> Map.merge(artifact_attrs, success_state(true))
      :missing -> bookkeeping_state(article, step_type)
    end
  end

  defp initial_item_step_state(article, step_type, definition, _mode) do
    item_step = Map.merge(definition, %{step_type: step_type})

    case reusable_artifact(article, item_step) do
      {:ok, artifact_attrs} -> Map.merge(artifact_attrs, success_state(true))
      :missing -> %{status: requested_status(article, step_type)}
    end
  end

  defp bookkeeping_state(
         %Article{extraction_status: "failed", extraction_metadata: metadata},
         "extraction"
       )
       when is_map(metadata) do
    if Map.get(metadata, "retryable") in [false, "false"],
      do: %{status: "failed", error_message: Map.get(metadata, "message")},
      else: %{status: "not_requested"}
  end

  defp bookkeeping_state(%Article{extraction_status: "skipped"}, "extraction"),
    do: %{status: "skipped"}

  defp bookkeeping_state(%Article{extraction: %ArticleExtraction{}}, "digestion"),
    do: %{status: "not_requested"}

  defp bookkeeping_state(_article, "digestion"), do: %{status: "blocked"}
  defp bookkeeping_state(_article, _step_type), do: %{status: "not_requested"}

  defp requested_status(
         %Article{extraction_status: "failed", extraction_metadata: metadata},
         "extraction"
       )
       when is_map(metadata) do
    if Map.get(metadata, "retryable") in [false, "false"], do: "failed", else: "pending"
  end

  defp requested_status(%Article{extraction_status: "skipped"}, "extraction"), do: "skipped"

  defp requested_status(_article, "extraction"), do: "pending"

  defp requested_status(%Article{extraction: %ArticleExtraction{}}, "digestion"),
    do: "pending"

  defp requested_status(_article, "digestion"), do: "blocked"
  defp requested_status(_article, _step_type), do: "pending"

  defp forced_status(_article, "extraction"), do: "pending"

  defp forced_status(%Article{extraction: %ArticleExtraction{}}, "digestion"),
    do: "pending"

  defp forced_status(_article, "digestion"), do: "blocked"
  defp forced_status(_article, _step_type), do: "pending"

  defp prerequisites_ready?(_article, "extraction"), do: true

  defp prerequisites_ready?(%Article{extraction: %ArticleExtraction{}}, "digestion"),
    do: true

  defp prerequisites_ready?(_article, _step_type), do: false

  defp reusable_artifact(%Article{extraction: %ArticleExtraction{} = extraction}, %{
         step_type: "extraction"
       }) do
    {:ok, %{article_extraction_id: extraction.id, article_digest_id: nil}}
  end

  defp reusable_artifact(
         %Article{extraction: %ArticleExtraction{} = extraction},
         %{
           step_type: "digestion",
           config_snapshot: %{"model" => model},
           article_digest: %ArticleDigest{} = digest
         }
       )
       when is_binary(model) do
    if digest.input_fingerprint == Digestion.input_fingerprint(extraction, model) do
      {:ok, %{article_extraction_id: nil, article_digest_id: digest.id}}
    else
      :missing
    end
  end

  defp reusable_artifact(
         %Article{
           extraction: %ArticleExtraction{} = extraction,
           digests: digests
         },
         %{step_type: "digestion", config_snapshot: %{"model" => model}}
       )
       when is_binary(model) and is_list(digests) do
    fingerprint = Digestion.input_fingerprint(extraction, model)

    digest =
      digests
      |> Enum.filter(&(&1.input_fingerprint == fingerprint))
      |> Enum.sort_by(&{&1.generated_at, &1.id}, :desc)
      |> List.first()

    case digest do
      %ArticleDigest{} = digest ->
        {:ok, %{article_extraction_id: nil, article_digest_id: digest.id}}

      nil ->
        :missing
    end
  end

  defp reusable_artifact(_article, _item_step), do: :missing

  defp success_state(reused?) do
    %{
      status: "succeeded",
      reused_artifact: reused?,
      error_message: nil,
      finished_at: DateTime.utc_now(:second)
    }
  end

  defp update_item_step!(item_step, attrs) do
    item_step
    |> GeneratedFeedItemStep.changeset(attrs)
    |> Repo.update!()
  end

  # Execution state flows only into item steps that still demand the attempt;
  # a cancelled row keeps its state and its historical link (audit IMP-03).
  # Every batch holding one of those rows is refreshed (audit IMP-01). A
  # failure that a permitted automatic retry will follow does not settle the
  # member (audit IMP-02).
  defp update_attempt_item_steps(attempt_id, attrs) do
    item_steps =
      GeneratedFeedItemStep
      |> where([item_step], item_step.latest_attempt_id == ^attempt_id)
      |> where([item_step], item_step.status != "cancelled")
      |> Repo.all()

    Enum.each(item_steps, &update_item_step!(&1, attrs))
    item_step_ids = Enum.map(item_steps, & &1.id)

    finalize? =
      attrs[:status] in @terminal_item_statuses and
        not (attrs[:status] == "failed" and retry_will_follow?(attempt_id))

    if finalize? and item_step_ids != [] do
      PipelineBatchMember
      |> where(
        [member],
        member.generated_feed_item_step_id in ^item_step_ids and is_nil(member.outcome)
      )
      |> Repo.update_all(set: [outcome: attrs[:status], outcome_at: DateTime.utc_now(:second)])
    end

    refresh_batches_for_item_steps(item_step_ids)
    :ok
  end

  defp retry_will_follow?(attempt_id) do
    case Repo.get(PipelineStepAttempt, attempt_id) do
      %PipelineStepAttempt{} = attempt -> automatic_rate_limit_retry?(attempt)
      nil -> false
    end
  end

  # Participation is immutable: the item step was served by this attempt.
  # Lineage: the attempt now serves the requesting batch (if any) and every
  # batch with an open member for this item step, which are marked enrolled.
  defp record_participation(batch_run_id, item_step_id, attempt_id) do
    now = DateTime.utc_now(:second)

    Repo.insert_all(
      PipelineItemStepAttempt,
      [
        %{
          generated_feed_item_step_id: item_step_id,
          pipeline_step_attempt_id: attempt_id,
          inserted_at: now
        }
      ],
      on_conflict: :nothing
    )

    if batch_run_id, do: mark_enrolled!(batch_run_id, item_step_id)
    record_batch_attempts(batch_run_id, item_step_id, attempt_id)
  end

  defp mark_enrolled!(batch_run_id, item_step_id) do
    PipelineBatchMember
    |> where(
      [member],
      member.batch_run_id == ^batch_run_id and
        member.generated_feed_item_step_id == ^item_step_id and is_nil(member.enrolled_at)
    )
    |> Repo.update_all(set: [enrolled_at: DateTime.utc_now(:second)])

    :ok
  end

  defp record_batch_attempts(batch_run_id, item_step_id, attempt_id) do
    open_batch_ids =
      PipelineBatchMember
      |> where(
        [member],
        member.generated_feed_item_step_id == ^item_step_id and is_nil(member.outcome)
      )
      |> select([member], member.batch_run_id)
      |> Repo.all()

    now = DateTime.utc_now(:second)

    rows =
      [batch_run_id | open_batch_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&%{batch_run_id: &1, pipeline_step_attempt_id: attempt_id, inserted_at: now})

    if rows != [], do: Repo.insert_all(PipelineBatchAttempt, rows, on_conflict: :nothing)
    :ok
  end

  defp reactivate_skipped_article_steps(article_id, step_type) do
    now = DateTime.utc_now(:second)

    GeneratedFeedItemStep
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> where(
      [item_step, item],
      item.article_id == ^article_id and item_step.step_type == ^step_type and
        item_step.status == "skipped"
    )
    |> Repo.update_all(
      set: [
        status: "pending",
        latest_attempt_id: nil,
        article_extraction_id: nil,
        article_digest_id: nil,
        reused_artifact: false,
        error_message: nil,
        started_at: nil,
        finished_at: nil,
        updated_at: now
      ]
    )

    :ok
  end

  defp advance_article_items(article_id) do
    GeneratedFeedItem
    |> where([item], item.article_id == ^article_id)
    |> select([item], item.id)
    |> Repo.all()
    |> Enum.each(&advance_item/1)

    :ok
  end

  defp materialize_step_on_ok({:ok, %PipelineStep{} = step} = result) do
    case materialize_step_items(step) do
      {:ok, _count} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp materialize_step_on_ok(result), do: result

  defp materialize_step_items(%PipelineStep{} = step) do
    GeneratedFeedItem
    |> where([item], item.generated_feed_id == ^step.generated_feed_id)
    |> preload(article: [:extraction, :digests])
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case ensure_item_step(item, step, :bookkeeping) do
        {:ok, _item_step} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp put_batch_run(changeset, nil), do: changeset

  defp put_batch_run(changeset, batch_run_id) do
    Ecto.Changeset.put_change(changeset, :batch_run_id, batch_run_id)
  end

  defp refresh_attempt_batch({:ok, %PipelineStepAttempt{} = attempt} = result) do
    _ = refresh_batch_run(attempt.batch_run_id)
    result
  end

  defp refresh_attempt_batch(result), do: result

  defp retry_items(%PipelineStepAttempt{} = attempt, item_step_ids) do
    consumers =
      GeneratedFeedItemStep
      |> where([item_step], item_step.latest_attempt_id == ^attempt.id)
      |> where([item_step], item_step.status != "cancelled")
      |> then(fn query ->
        if is_list(item_step_ids),
          do: where(query, [item_step], item_step.id in ^item_step_ids),
          else: query
      end)
      |> select([item_step], item_step.generated_feed_item_id)
      |> Repo.all()

    item_ids = consumers |> Enum.reject(&is_nil/1) |> Enum.uniq()

    GeneratedFeedItem
    |> where([item], item.id in ^item_ids)
    |> preload([:generated_feed, article: [:extraction, :digests]])
    |> Repo.all()
  end

  defp automatic_retry_candidates(step_type) do
    latest_attempt_ids =
      PipelineStepAttempt
      |> where([attempt], attempt.step_type == ^step_type)
      |> group_by([attempt], attempt.article_id)
      |> select([attempt], max(attempt.id))

    PipelineStepAttempt
    |> join(:inner, [attempt], article in Article, on: article.id == attempt.article_id)
    |> where(
      [attempt, article],
      attempt.id in subquery(latest_attempt_ids) and attempt.status == "failed" and
        attempt.retryable == true and attempt.failure_kind == "rate_limited" and
        article.extraction_status == "failed"
    )
    |> order_by([attempt, _article], asc: attempt.inserted_at, asc: attempt.id)
    |> Repo.all()
  end

  defp automatic_rate_limit_retry?(%PipelineStepAttempt{} = attempt) do
    attempt.step_type == "extraction" and attempt.status == "failed" and attempt.retryable and
      attempt.failure_kind == "rate_limited" and
      rate_limit_failure_streak(attempt) <= @automatic_rate_limit_retries
  end

  defp retry_request_metadata(opts) do
    %{
      "retry_origin" => Keyword.get(opts, :origin, "manual"),
      "retry_number" => Keyword.get(opts, :retry_number),
      "retry_limit" => Keyword.get(opts, :retry_limit)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp rate_limit_failure_streak(%PipelineStepAttempt{} = attempt) do
    last_successful_attempt_id =
      PipelineStepAttempt
      |> where(
        [candidate],
        candidate.article_id == ^attempt.article_id and
          candidate.step_type == ^attempt.step_type and candidate.id < ^attempt.id and
          candidate.status in ["succeeded", "skipped"]
      )
      |> select([candidate], max(candidate.id))
      |> Repo.one()
      |> then(&(&1 || 0))

    PipelineStepAttempt
    |> where(
      [candidate],
      candidate.article_id == ^attempt.article_id and
        candidate.step_type == ^attempt.step_type and candidate.id > ^last_successful_attempt_id and
        candidate.id <= ^attempt.id and candidate.status == "failed" and
        candidate.retryable == true and candidate.failure_kind == "rate_limited"
    )
    |> Repo.aggregate(:count, :id)
  end

  defp refresh_active_batch_runs do
    list_running_feed_batches()
    |> Enum.each(&refresh_batch_run(&1.id))
  end

  defp active_attempt(step_type, article_id) do
    Repo.one(
      from attempt in PipelineStepAttempt,
        where:
          attempt.step_type == ^step_type and attempt.article_id == ^article_id and
            attempt.status in ["queued", "running"],
        limit: 1
    )
  end

  defp dispatch(%PipelineStepAttempt{step_type: "extraction"} = attempt, article) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      site_host = article |> extraction_url() |> Content.site_host()

      if is_binary(site_host) do
        Newspaper.Processing.Dispatcher.enqueue(
          attempt.id,
          site_host,
          PriorityQueue.priority_for(attempt)
        )
      else
        fail_dispatched_attempt(
          attempt.id,
          "invalid_url",
          "Article has no usable extraction URL",
          false
        )
      end
    end
  end

  defp dispatch(%PipelineStepAttempt{step_type: "digestion"} = attempt, _article) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      Newspaper.Digestion.Dispatcher.enqueue(attempt.id, PriorityQueue.priority_for(attempt))
    end
  end

  defp dispatch(_attempt, _article), do: :ok

  defp extraction_url(article), do: article.resolved_url || article.canonical_url

  defp active_attempt_conflict?(changeset) do
    Enum.any?(changeset.errors, fn
      {_field, {_message, options}} ->
        options[:constraint_name] == "pipeline_step_attempts_one_active_per_type"

      _ ->
        false
    end)
  end

  defp config_attrs(attrs, fallback \\ %{}) do
    nested = Map.get(attrs, "config") || Map.get(attrs, :config) || %{}

    fallback
    |> Map.merge(stringify_keys(nested))
  end

  defp attr(attrs, key), do: Map.get(attrs, key) || Map.get(attrs, String.to_existing_atom(key))

  defp boolean_attr(attrs, key, default) do
    case attr(attrs, key) do
      nil -> default
      value when value in [true, "true", "on", "1", 1] -> true
      _ -> false
    end
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  defp broadcast_on_ok({:ok, value}) do
    Newspaper.Events.broadcast_data_changed(:processing_changed)
    {:ok, value}
  end

  defp broadcast_on_ok(result), do: result
end
