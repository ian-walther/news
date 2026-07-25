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
    PipelineStep,
    PipelineStepAttempt,
    PriorityQueue,
    Registry
  }

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

  def start_feed_batch(feed_id, trigger \\ "manual", step_type \\ "extraction")

  def start_feed_batch(feed_id, trigger, step_type)
      when is_integer(feed_id) and is_binary(step_type) do
    feed = Newspaper.Publishing.get_generated_feed!(feed_id)
    steps = list_enabled_steps(feed.id, step_type)

    if steps == [] do
      {:error, {:no_enabled_step, step_type}}
    else
      with {:ok, batch} <- create_feed_batch(feed, steps, trigger, step_type) do
        case BatchDispatcher.enqueue(batch.id) do
          :ok ->
            {:ok, batch}

          {:error, reason} ->
            _ = fail_feed_batch(batch.id, reason)
            {:error, reason}
        end
      end
    end
  end

  def list_running_feed_batches do
    Run
    |> where([run], run.run_type == "pipeline_batch" and run.status == "running")
    |> order_by([run], asc: run.started_at, asc: run.id)
    |> Repo.all()
  end

  def resume_feed_batch(batch_id) when is_integer(batch_id) do
    batch = Operations.get_run!(batch_id)

    if batch.run_type == "pipeline_batch" and batch.status == "running" do
      with {:ok, feed_id, step_type} <- feed_batch_context(batch),
           feed <- Newspaper.Publishing.get_generated_feed!(feed_id),
           items <- Newspaper.Publishing.list_items_for_feed(feed),
           :ok <- enqueue_batch_items(items, batch.id, step_type),
           {:ok, batch} <- refresh_batch_run(batch.id, length(items)) do
        {:ok, batch}
      else
        {:error, reason} -> fail_feed_batch(batch.id, reason)
      end
    else
      {:ok, batch}
    end
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
        blocked: Map.get(status_counts, "blocked", 0),
        queued: Map.get(status_counts, "queued", 0),
        running: Map.get(status_counts, "running", 0),
        failed: Map.get(status_counts, "failed", 0),
        skipped: Map.get(status_counts, "skipped", 0)
      }

      {step.id, counts}
    end)
  end

  def request_item_step(%GeneratedFeedItem{} = item, step_type, opts \\ []) do
    mode = if Keyword.get(opts, :force, false), do: :force, else: :requested

    advance_opts =
      if mode == :force, do: Keyword.put(opts, :force_step_type, step_type), else: opts

    with [step] <- list_enabled_steps(item.generated_feed_id, step_type),
         :ok <- reconcile_prior_steps(item, step),
         {:ok, _item_step} <- ensure_item_step(item, step, mode),
         {:ok, attempts} <- advance_item(item.id, advance_opts) do
      {:ok, attempts}
    else
      [] -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
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
          |> Map.merge(success_state(true))
          |> Map.merge(%{pipeline_step_id: step.id, position: step.position})

        item_step
        |> GeneratedFeedItemStep.changeset(attrs)
        |> Repo.update()

      :missing when item_step.status == "succeeded" and mode == :requested ->
        {:ok, item_step}

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
        {:ok, item_step}
    end
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
       when status in ["not_requested", "queued", "running", "failed"] do
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

  def create_step(%GeneratedFeed{} = feed, attrs) do
    implementation_key = attr(attrs, "implementation_key")

    with {:ok, implementation} <- Registry.fetch_step(implementation_key),
         {:ok, config} <- Registry.normalize_step_config(implementation_key, config_attrs(attrs)) do
      %PipelineStep{}
      |> PipelineStep.changeset(%{
        generated_feed_id: feed.id,
        step_type: implementation.step_type,
        implementation_key: implementation.key,
        position: next_position(feed.id),
        enabled: boolean_attr(attrs, "enabled", true),
        config: config
      })
      |> Repo.insert()
      |> materialize_step_on_ok()
      |> broadcast_on_ok()
    end
  end

  def create_extraction_step(%GeneratedFeed{} = feed) do
    create_step(feed, %{"implementation_key" => Registry.site_policy_step_key()})
  end

  def create_digest_step(%GeneratedFeed{} = feed) do
    with [_extraction_step] <- list_enabled_steps(feed.id, "extraction"),
         model when is_binary(model) and model != "" <- Operations.get_settings().ollama_model do
      create_step(feed, %{"implementation_key" => Registry.article_digest_step_key()})
    else
      [] -> {:error, :extraction_step_required}
      _model -> {:error, :ollama_model_not_configured}
    end
  end

  def update_step(%PipelineStep{} = step, attrs) do
    with {:ok, config} <-
           Registry.normalize_step_config(
             step.implementation_key,
             config_attrs(attrs, step.config)
           ) do
      step
      |> PipelineStep.changeset(%{
        enabled: boolean_attr(attrs, "enabled", step.enabled),
        config: config
      })
      |> Repo.update()
      |> materialize_step_on_ok()
      |> broadcast_on_ok()
    end
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

  def delete_step(%PipelineStep{} = step) do
    step
    |> Repo.delete()
    |> broadcast_on_ok()
  end

  def move_step(%PipelineStep{} = step, direction) when direction in [:up, :down] do
    steps = list_steps(step.generated_feed_id)
    index = Enum.find_index(steps, &(&1.id == step.id))
    other_index = if direction == :up, do: index - 1, else: index + 1

    case Enum.at(steps, other_index) do
      nil ->
        {:ok, step}

      other ->
        Repo.transaction(fn ->
          step
          |> PipelineStep.changeset(%{position: other.position})
          |> Repo.update!()

          other
          |> PipelineStep.changeset(%{position: step.position})
          |> Repo.update!()

          Repo.get!(PipelineStep, step.id)
        end)
        |> broadcast_on_ok()
    end
  end

  def list_attempts_for_article(article_id) do
    PipelineStepAttempt
    |> where([attempt], attempt.article_id == ^article_id)
    |> order_by([attempt], desc: attempt.inserted_at)
    |> preload([:pipeline_step, :generated_feed_item])
    |> Repo.all()
  end

  def list_attempts_for_batch(batch_run_id) when is_integer(batch_run_id) do
    PipelineStepAttempt
    |> where([attempt], attempt.batch_run_id == ^batch_run_id)
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
    |> preload([
      :article,
      :pipeline_step,
      :batch_run,
      :runs,
      generated_feed_item: :generated_feed,
      generated_feed_item_step: [generated_feed_item: :generated_feed],
      affected_item_steps: [generated_feed_item: :generated_feed]
    ])
    |> Repo.all()
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
    where(query, [attempt], attempt.batch_run_id == ^batch_run_id)
  end

  defp filter_attempt_batch(query, _batch_run_id), do: query

  defp filter_attempt_feed(query, generated_feed_id) when is_integer(generated_feed_id) do
    feed_item_ids =
      from item in GeneratedFeedItem,
        where: item.generated_feed_id == ^generated_feed_id,
        select: item.id

    affected_attempt_ids =
      from item_step in GeneratedFeedItemStep,
        join: item in GeneratedFeedItem,
        on: item.id == item_step.generated_feed_item_id,
        where:
          item.generated_feed_id == ^generated_feed_id and
            not is_nil(item_step.latest_attempt_id),
        select: item_step.latest_attempt_id

    where(
      query,
      [attempt],
      attempt.generated_feed_item_id in subquery(feed_item_ids) or
        attempt.id in subquery(affected_attempt_ids)
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

  def list_recent_batches(limit \\ 5) do
    Run
    |> where([run], run.run_type == "pipeline_batch")
    |> order_by([run], desc: run.started_at, desc: run.id)
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
    |> order_by([attempt],
      asc_nulls_first: attempt.batch_run_id,
      asc: attempt.inserted_at,
      asc: attempt.id
    )
    |> Repo.all()
  end

  def requeue_interrupted_attempts(step_type \\ nil) do
    interrupted_query =
      PipelineStepAttempt
      |> where([attempt], attempt.status == "running")
      |> then(fn query ->
        if is_binary(step_type),
          do: where(query, [attempt], attempt.step_type == ^step_type),
          else: query
      end)

    interrupted_ids =
      interrupted_query
      |> select([attempt], attempt.id)
      |> Repo.all()

    {count, _rows} =
      interrupted_query
      |> Repo.update_all(
        set: [
          status: "queued",
          started_at: nil,
          finished_at: nil,
          error_message: "Application restarted while attempt was running"
        ]
      )

    GeneratedFeedItemStep
    |> where([item_step], item_step.latest_attempt_id in ^interrupted_ids)
    |> Repo.update_all(
      set: [
        status: "queued",
        started_at: nil,
        finished_at: nil,
        error_message: "Application restarted while attempt was running"
      ]
    )

    close_interrupted_runs(interrupted_ids)

    refresh_active_batch_runs()
    count
  end

  defp close_interrupted_runs([]), do: :ok

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

  def retry_attempt(attempt_id, opts \\ []) do
    attempt = get_attempt!(attempt_id)
    request_metadata = retry_request_metadata(opts)

    attempt
    |> retry_items()
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, attempts} ->
      case request_item_step(item, attempt.step_type,
             force: true,
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
      retry_attempt(attempt.id,
        origin: "automatic_rate_limit",
        retry_number: rate_limit_failure_streak(attempt),
        retry_limit: @automatic_rate_limit_retries
      )
    else
      {:ok, nil}
    end
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

  def mark_attempt_running(%PipelineStepAttempt{} = attempt) do
    now = DateTime.utc_now(:second)

    result =
      attempt
      |> PipelineStepAttempt.changeset(%{
        status: "running",
        started_at: now
      })
      |> Repo.update()
      |> broadcast_on_ok()

    if match?({:ok, _attempt}, result) do
      update_attempt_item_steps(attempt.id, %{status: "running", started_at: now})
    end

    refresh_attempt_batch(result)
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

  def refresh_batch_run(batch_run_id, items_considered) when is_integer(batch_run_id) do
    batch = Operations.get_run!(batch_run_id)

    status_counts =
      PipelineStepAttempt
      |> where([attempt], attempt.batch_run_id == ^batch_run_id)
      |> group_by([attempt], attempt.status)
      |> select([attempt], {attempt.status, count(attempt.id)})
      |> Repo.all()
      |> Map.new()

    counts = %{
      "queued" => Map.get(status_counts, "queued", 0),
      "running" => Map.get(status_counts, "running", 0),
      "succeeded" => Map.get(status_counts, "succeeded", 0),
      "failed" => Map.get(status_counts, "failed", 0),
      "skipped" => Map.get(status_counts, "skipped", 0)
    }

    total = Enum.sum(Map.values(counts))
    items_considered = items_considered || batch.summary_counts["items_considered"] || total

    summary =
      counts
      |> Map.put("total", total)
      |> Map.put("items_considered", items_considered)
      |> Map.update!("skipped", &(&1 + max(items_considered - total, 0)))

    active = counts["queued"] + counts["running"]

    cond do
      active > 0 ->
        Operations.update_run(batch, %{
          status: "running",
          finished_at: nil,
          summary_counts: summary
        })

      is_nil(batch.finished_at) ->
        status = if counts["failed"] > 0, do: "failed", else: "succeeded"
        Operations.finish_run(batch, status, %{summary_counts: summary})

      true ->
        Operations.update_run(batch, %{summary_counts: summary})
    end
  end

  def change_step(%PipelineStep{} = step, attrs \\ %{}), do: PipelineStep.changeset(step, attrs)

  defp enqueue_batch_items(items, batch_run_id, step_type) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case request_item_step(item, step_type, batch_run_id: batch_run_id) do
        {:ok, _attempts} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_feed_batch(feed, steps, trigger, step_type) do
    Operations.start_run(
      "pipeline_batch",
      trigger,
      %{
        "batch_type" => "process_existing_#{step_type}",
        "generated_feed_id" => feed.id,
        "generated_feed_title" => feed.title,
        "step_type" => step_type
      },
      %{"pipeline_step_ids" => Enum.map(steps, & &1.id)}
    )
  end

  defp feed_batch_context(batch) do
    with feed_id when is_integer(feed_id) <- batch.related["generated_feed_id"],
         step_type when step_type in ["extraction", "digestion"] <-
           batch.related["step_type"] do
      {:ok, feed_id, step_type}
    else
      _ -> {:error, :invalid_batch_context}
    end
  end

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

            dispatch(attempt, article)
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

  defp update_attempt_item_steps(attempt_id, attrs) do
    GeneratedFeedItemStep
    |> where([item_step], item_step.latest_attempt_id == ^attempt_id)
    |> Repo.all()
    |> Enum.each(&update_item_step!(&1, attrs))
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

  defp retry_items(%PipelineStepAttempt{} = attempt) do
    affected_item_ids =
      GeneratedFeedItemStep
      |> where([item_step], item_step.latest_attempt_id == ^attempt.id)
      |> select([item_step], item_step.generated_feed_item_id)
      |> Repo.all()

    item_ids =
      [attempt.generated_feed_item_id | affected_item_ids]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

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
    PipelineStepAttempt
    |> where(
      [attempt],
      not is_nil(attempt.batch_run_id) and attempt.status in ["queued", "running"]
    )
    |> select([attempt], attempt.batch_run_id)
    |> distinct(true)
    |> Repo.all()
    |> Enum.each(&refresh_batch_run/1)
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

  defp next_position(feed_id) do
    Repo.one(
      from step in PipelineStep,
        where: step.generated_feed_id == ^feed_id,
        select: coalesce(max(step.position), -1)
    ) + 1
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
