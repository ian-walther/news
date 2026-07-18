defmodule Newspaper.Processing do
  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Content.{Article, ArticleDigest, ArticleExtraction}
  alias Newspaper.Digestion
  alias Newspaper.Operations
  alias Newspaper.Operations.Run
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineStep, PipelineStepAttempt, Registry}
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

  def extraction_eligible_article_ids([]), do: MapSet.new()

  def extraction_eligible_article_ids(article_ids) when is_list(article_ids) do
    step_eligible_article_ids(article_ids, "extraction")
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

  def enqueue_feed(feed_id, opts \\ []) when is_integer(feed_id) do
    GeneratedFeedItem
    |> where([item], item.generated_feed_id == ^feed_id)
    |> preload([:generated_feed, article: [:extraction, :digests]])
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case enqueue_item(item, opts) do
        {:ok, attempts} -> {:cont, {:ok, count + length(attempts)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def start_feed_batch(feed_id, trigger \\ "manual", step_type \\ "extraction")

  def start_feed_batch(feed_id, trigger, step_type)
      when is_integer(feed_id) and is_binary(step_type) do
    feed = Newspaper.Publishing.get_generated_feed!(feed_id)
    steps = list_enabled_steps(feed.id, step_type)

    if steps == [] do
      {:error, {:no_enabled_step, step_type}}
    else
      items = Newspaper.Publishing.list_items_for_feed(feed)

      with {:ok, batch} <-
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
             ),
           :ok <- enqueue_batch_items(items, batch.id, step_type),
           {:ok, batch} <- refresh_batch_run(batch.id, length(items)) do
        {:ok, batch}
      end
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
      missing_artifacts = missing_extraction_artifacts(feed_id, step, missing)
      missing_failures = missing_terminal_failures(feed_id, step, missing - missing_artifacts)

      missing_blocked =
        missing_prerequisite_blocks(
          feed_id,
          step,
          missing - missing_artifacts - missing_failures
        )

      counts = %{
        total: item_count,
        ready: Map.get(status_counts, "succeeded", 0) + missing_artifacts,
        not_requested:
          Map.get(status_counts, "not_requested", 0) +
            max(missing - missing_artifacts - missing_failures - missing_blocked, 0),
        blocked: Map.get(status_counts, "blocked", 0) + missing_blocked,
        queued: Map.get(status_counts, "queued", 0),
        running: Map.get(status_counts, "running", 0),
        failed: Map.get(status_counts, "failed", 0) + missing_failures,
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
         {:ok, _item_step} <- ensure_item_step(item, step, mode),
         {:ok, attempts} <- advance_item(item.id, advance_opts) do
      {:ok, attempts}
    else
      [] -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
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
      when mode in [:future, :requested, :force] do
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

      %GeneratedFeedItemStep{status: "succeeded"} = item_step when mode == :requested ->
        {:ok, item_step}

      %GeneratedFeedItemStep{} = item_step when mode in [:requested, :force] ->
        status =
          if mode == :force,
            do: forced_status(item.article, step.step_type),
            else: requested_status(item.article, step.step_type)

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

      %GeneratedFeedItemStep{} = item_step ->
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

  defp advance_item_step(_item, %{status: "skipped"} = item_step, _opts) do
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
      |> broadcast_on_ok()
    end
  end

  def create_extraction_step(%GeneratedFeed{} = feed) do
    create_step(feed, %{"implementation_key" => Registry.site_policy_step_key()})
  end

  def create_digest_step(%GeneratedFeed{} = feed) do
    case Operations.get_settings().ollama_model do
      model when is_binary(model) and model != "" ->
        create_step(feed, %{"implementation_key" => Registry.article_digest_step_key()})

      _model ->
        {:error, :ollama_model_not_configured}
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
      |> broadcast_on_ok()
    end
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
          unavailable: counts.failed,
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
    |> order_by([attempt], asc: attempt.inserted_at)
    |> Repo.all()
  end

  def requeue_interrupted_attempts do
    interrupted_ids =
      PipelineStepAttempt
      |> where([attempt], attempt.status == "running")
      |> select([attempt], attempt.id)
      |> Repo.all()

    {count, _rows} =
      PipelineStepAttempt
      |> where([attempt], attempt.status == "running")
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

    refresh_active_batch_runs()
    count
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

  def retry_attempt(attempt_id) do
    attempt = get_attempt!(attempt_id)

    if attempt.generated_feed_item do
      request_item_step(attempt.generated_feed_item, attempt.step_type, force: true)
      |> case do
        {:ok, [retry_attempt | _rest]} -> {:ok, retry_attempt}
        {:ok, []} -> {:error, :step_not_available}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :step_not_available}
    end
  end

  def enqueue(
        %PipelineStep{} = step,
        %Article{} = article,
        %GeneratedFeedItem{} = item,
        opts \\ []
      ) do
    with {:ok, item_step} <- ensure_item_step(item, step, :requested) do
      enqueue_item_step(%{item | article: article}, item_step, opts)
    end
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
      when status in ["succeeded", "failed"] do
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

  def attach_artifact(%PipelineStepAttempt{} = attempt, %ArticleExtraction{} = extraction) do
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
      "failed" => Map.get(status_counts, "failed", 0)
    }

    total = Enum.sum(Map.values(counts))
    items_considered = items_considered || batch.summary_counts["items_considered"] || total

    summary =
      counts
      |> Map.put("total", total)
      |> Map.put("items_considered", items_considered)
      |> Map.put("skipped", max(items_considered - total, 0))

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
              "definition_fingerprint" => item_step.definition_fingerprint
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

  defp initial_item_step_state(article, step_type, definition, _mode) do
    item_step = Map.merge(definition, %{step_type: step_type})

    case reusable_artifact(article, item_step) do
      {:ok, artifact_attrs} -> Map.merge(artifact_attrs, success_state(true))
      :missing -> %{status: requested_status(article, step_type)}
    end
  end

  defp requested_status(
         %Article{extraction_status: "failed", extraction_metadata: metadata},
         "extraction"
       )
       when is_map(metadata) do
    if Map.get(metadata, "retryable") in [false, "false"], do: "failed", else: "pending"
  end

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

  defp advance_article_items(article_id) do
    GeneratedFeedItem
    |> where([item], item.article_id == ^article_id)
    |> select([item], item.id)
    |> Repo.all()
    |> Enum.each(&advance_item/1)

    :ok
  end

  defp missing_extraction_artifacts(_feed_id, %{step_type: step_type}, _missing)
       when step_type != "extraction",
       do: 0

  defp missing_extraction_artifacts(_feed_id, _step, missing) when missing <= 0, do: 0

  defp missing_extraction_artifacts(feed_id, step, _missing) do
    Repo.aggregate(
      from(item in GeneratedFeedItem,
        join: extraction in ArticleExtraction,
        on: extraction.article_id == item.article_id,
        left_join: item_step in GeneratedFeedItemStep,
        on:
          item_step.generated_feed_item_id == item.id and
            item_step.pipeline_step_id == ^step.id,
        where: item.generated_feed_id == ^feed_id and is_nil(item_step.id)
      ),
      :count,
      :id
    )
  end

  defp missing_terminal_failures(_feed_id, %{step_type: step_type}, _missing)
       when step_type != "extraction",
       do: 0

  defp missing_terminal_failures(_feed_id, _step, missing) when missing <= 0, do: 0

  defp missing_terminal_failures(feed_id, step, _missing) do
    Repo.aggregate(
      from(item in GeneratedFeedItem,
        join: article in Article,
        on: article.id == item.article_id,
        left_join: item_step in GeneratedFeedItemStep,
        on:
          item_step.generated_feed_item_id == item.id and
            item_step.pipeline_step_id == ^step.id,
        where:
          item.generated_feed_id == ^feed_id and is_nil(item_step.id) and
            article.extraction_status == "failed" and
            fragment("(?->>'retryable') = 'false'", article.extraction_metadata)
      ),
      :count,
      :id
    )
  end

  defp missing_prerequisite_blocks(_feed_id, %{step_type: step_type}, _missing)
       when step_type != "digestion",
       do: 0

  defp missing_prerequisite_blocks(_feed_id, _step, missing) when missing <= 0, do: 0

  defp missing_prerequisite_blocks(feed_id, step, _missing) do
    Repo.aggregate(
      from(item in GeneratedFeedItem,
        left_join: extraction in ArticleExtraction,
        on: extraction.article_id == item.article_id,
        left_join: item_step in GeneratedFeedItemStep,
        on:
          item_step.generated_feed_item_id == item.id and
            item_step.pipeline_step_id == ^step.id,
        where:
          item.generated_feed_id == ^feed_id and is_nil(item_step.id) and
            is_nil(extraction.id)
      ),
      :count,
      :id
    )
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
      article
      |> extraction_url()
      |> Content.site_host()
      |> then(&Newspaper.Processing.Dispatcher.enqueue(attempt.id, &1))
    end
  end

  defp dispatch(%PipelineStepAttempt{step_type: "digestion"} = attempt, _article) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      Newspaper.Digestion.Dispatcher.enqueue(attempt.id)
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
