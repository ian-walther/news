defmodule Newspaper.Processing do
  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Content.Article
  alias Newspaper.Processing.{PipelineStep, PipelineStepAttempt, Registry}
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

  def get_step!(id), do: Repo.get!(PipelineStep, id)

  def enqueue_item(%GeneratedFeedItem{} = item, opts \\ []) do
    item = Repo.preload(item, [:generated_feed, article: :extraction])
    force? = Keyword.get(opts, :force, false)

    cond do
      not item.generated_feed.process_items and not force? ->
        {:ok, []}

      item.article.extraction && not force? ->
        {:ok, []}

      true ->
        attempts =
          item.generated_feed_id
          |> list_enabled_steps("extraction")
          |> Enum.map(&enqueue(&1, item.article, item))

        case Enum.find(attempts, &match?({:error, _reason}, &1)) do
          nil -> {:ok, Enum.map(attempts, fn {:ok, attempt} -> attempt end)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  def enqueue_feed(feed_id, opts \\ []) when is_integer(feed_id) do
    GeneratedFeedItem
    |> where([item], item.generated_feed_id == ^feed_id)
    |> preload([:generated_feed, article: :extraction])
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case enqueue_item(item, opts) do
        {:ok, attempts} -> {:cont, {:ok, count + length(attempts)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def enqueue_article(article_id, opts \\ []) when is_integer(article_id) do
    GeneratedFeedItem
    |> where([item], item.article_id == ^article_id)
    |> preload([:generated_feed, article: :extraction])
    |> Repo.all()
    |> Enum.reduce_while({:ok, 0}, fn item, {:ok, count} ->
      case enqueue_item(item, Keyword.put_new(opts, :force, true)) do
        {:ok, attempts} -> {:cont, {:ok, count + length(attempts)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def create_step(%GeneratedFeed{} = feed, attrs) do
    implementation_key = attr(attrs, "implementation_key")

    with {:ok, implementation} <- Registry.fetch(implementation_key),
         {:ok, config} <- Registry.normalize_config(implementation_key, config_attrs(attrs)) do
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

  def update_step(%PipelineStep{} = step, attrs) do
    with {:ok, config} <-
           Registry.normalize_config(step.implementation_key, config_attrs(attrs, step.config)) do
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

  def list_queued_attempts do
    PipelineStepAttempt
    |> where([attempt], attempt.status == "queued")
    |> order_by([attempt], asc: attempt.inserted_at)
    |> Repo.all()
  end

  def requeue_interrupted_attempts do
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

    count
  end

  def get_attempt!(id) do
    PipelineStepAttempt
    |> Repo.get!(id)
    |> Repo.preload([:pipeline_step, :article, generated_feed_item: :generated_feed])
  end

  def retry_attempt(attempt_id) do
    attempt = get_attempt!(attempt_id)
    enqueue(attempt.pipeline_step, attempt.article, attempt.generated_feed_item)
  end

  def enqueue(%PipelineStep{} = step, %Article{} = article, %GeneratedFeedItem{} = item) do
    case active_attempt(step.step_type, article.id) do
      %PipelineStepAttempt{} = attempt ->
        {:ok, attempt}

      nil ->
        %PipelineStepAttempt{}
        |> PipelineStepAttempt.changeset(%{
          pipeline_step_id: step.id,
          article_id: article.id,
          generated_feed_item_id: item.id,
          implementation_key: step.implementation_key,
          step_type: step.step_type,
          status: "queued",
          input_snapshot: %{
            "article_id" => article.id,
            "generated_feed_item_id" => item.id,
            "config" => step.config
          }
        })
        |> Repo.insert()
        |> case do
          {:ok, attempt} ->
            Content.set_extraction_status(article, "queued")
            dispatch(attempt, article)
            Newspaper.Events.broadcast_data_changed(:processing_changed)
            {:ok, attempt}

          {:error, changeset} = error ->
            if active_attempt_conflict?(changeset) do
              {:ok, active_attempt(step.step_type, article.id)}
            else
              error
            end
        end
    end
  end

  def mark_attempt_running(%PipelineStepAttempt{} = attempt) do
    attempt
    |> PipelineStepAttempt.changeset(%{
      status: "running",
      started_at: DateTime.utc_now(:second)
    })
    |> Repo.update()
    |> broadcast_on_ok()
  end

  def finish_attempt(%PipelineStepAttempt{} = attempt, status, attrs \\ %{})
      when status in ["succeeded", "failed"] do
    attrs =
      attrs
      |> Map.put(:status, status)
      |> Map.put(:finished_at, DateTime.utc_now(:second))

    attempt
    |> PipelineStepAttempt.changeset(attrs)
    |> Repo.update()
    |> broadcast_on_ok()
  end

  def change_step(%PipelineStep{} = step, attrs \\ %{}), do: PipelineStep.changeset(step, attrs)

  defp active_attempt(step_type, article_id) do
    Repo.one(
      from attempt in PipelineStepAttempt,
        where:
          attempt.step_type == ^step_type and attempt.article_id == ^article_id and
            attempt.status in ["queued", "running"],
        limit: 1
    )
  end

  defp dispatch(attempt, article) do
    if Application.get_env(:newspaper, :processing_dispatcher_enabled, true) do
      article
      |> extraction_url()
      |> Content.site_host()
      |> then(&Newspaper.Processing.Dispatcher.enqueue(attempt.id, &1))
    end
  end

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
    |> Map.merge(Map.take(stringify_keys(attrs), ["timeout_ms", "minimum_text_length"]))
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
