defmodule Newspaper.Operations.Attention do
  @moduledoc """
  The derived attention inbox: what currently needs an operator, grouped by
  cause, each group with one correct action. Nothing here is filed or
  acknowledged — fixing the cause makes the group disappear.

  Group kinds:

  - `:step_failed` — item steps in `failed`, by step, failure kind, and feed
  - `:site_backoff` — hosts whose extraction backoff is still in the future
  - `:feed_fetch_failed` — input feeds whose last fetch failed
  - `:entry_failed` — unresolved pre-pipeline/publication failure records
  - `:stuck_run` — running operations with no live owner past their stage
    timeout (`:abandoned`) or a live owner running longer than expected
    (`:slow`, informational)
  """

  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Intake.InputFeed
  alias Newspaper.Operations
  alias Newspaper.Operations.Run
  alias Newspaper.Processing
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineStepAttempt, Registry}
  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Repo

  @entry_failure_types ~w(raw_item_ingestion_failed raw_item_processing_failed generated_feed_item_create_failed)
  @stage_timeouts_seconds %{
    "fetch_all" => 600,
    "fetch_input_feed" => 120,
    "process_input_feed" => 600,
    "process_intake_group" => 600,
    "backfill_output_feed" => 900,
    "rerender_output_feed" => 900
  }

  def entry_failure_types, do: @entry_failure_types

  def groups(now \\ DateTime.utc_now(:second)) do
    step_failure_groups() ++
      site_backoff_groups(now) ++
      feed_fetch_groups() ++
      entry_failure_groups() ++
      stuck_run_groups(now)
  end

  def count(now \\ DateTime.utc_now(:second)) do
    Enum.count(groups(now), &(&1.action != nil))
  end

  @doc "Executes a group's action. Returns `{:ok, message}` or `{:error, reason}`."
  def perform({:retry_items, feed_id, step_type, item_step_ids}) do
    case Processing.start_feed_batch(feed_id, "manual", step_type,
           selection: {:items, item_step_ids}
         ) do
      {:ok, _batch} -> {:ok, "#{Registry.step_label(step_type)} retry batch started"}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform({:try_now, site_host}) do
    case Newspaper.Processing.Dispatcher.retry_now(site_host) do
      {:started, _pid} -> {:ok, "Retrying #{site_host} now"}
      :already_running -> {:ok, "#{site_host} already has an extraction running"}
      :empty -> {:ok, "No queued articles for #{site_host}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def perform({:refetch, input_feed_id}) do
    feed = Newspaper.Intake.get_input_feed!(input_feed_id)

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Newspaper.Pipeline.fetch_input_feed(feed, "manual", ignore_validators: true)
    end)

    {:ok, "Refetching #{feed.name}"}
  end

  def perform({:retry_entries, failure_ids}) do
    results = Enum.map(failure_ids, &Newspaper.Pipeline.retry_entry_failure/1)
    retried = Enum.count(results, &match?({:ok, _}, &1))
    {:ok, "Retried #{retried} of #{length(failure_ids)} entries"}
  end

  def perform({:close_run, run_id}) do
    case Operations.close_run_as_failed(run_id) do
      {:ok, _run} -> {:ok, "Run ##{run_id} closed as failed"}
      {:error, :not_running} -> {:error, :run_already_finished}
    end
  end

  def perform(nil), do: {:error, :no_action}

  defp step_failure_groups do
    GeneratedFeedItemStep
    |> join(:inner, [item_step], item in GeneratedFeedItem,
      on: item.id == item_step.generated_feed_item_id
    )
    |> join(:inner, [_item_step, item], feed in GeneratedFeed,
      on: feed.id == item.generated_feed_id
    )
    |> join(:left, [item_step], attempt in PipelineStepAttempt,
      on: attempt.id == item_step.latest_attempt_id
    )
    |> where([item_step], item_step.status == "failed")
    |> select([item_step, item, feed, attempt], %{
      item_step_id: item_step.id,
      step_type: item_step.step_type,
      feed_id: feed.id,
      feed_title: feed.title,
      failure_kind: coalesce(attempt.failure_kind, "failed"),
      message: coalesce(attempt.error_message, item_step.error_message),
      retryable: attempt.retryable,
      failed_at: item_step.finished_at
    })
    |> Repo.all()
    |> Enum.group_by(&{&1.step_type, &1.failure_kind, &1.feed_id})
    |> Enum.map(fn {{step_type, failure_kind, feed_id}, rows} ->
      latest = Enum.max_by(rows, &(&1.failed_at || ~U[1970-01-01 00:00:00Z]), DateTime)

      %{
        id: "step-#{step_type}-#{failure_kind}-#{feed_id}",
        kind: :step_failed,
        stage: step_type,
        title: NewspaperWeb.AdminLive.Format.failure_type_label("pipeline_step_#{failure_kind}"),
        subject: hd(rows).feed_title,
        detail: latest.message,
        note: if(latest.retryable, do: "Retryable", else: "Not retried automatically"),
        count: length(rows),
        latest_at: latest.failed_at,
        action: {:retry_items, feed_id, step_type, Enum.map(rows, & &1.item_step_id)},
        action_label: "Retry #{length(rows)}",
        items:
          Enum.map(rows, fn row ->
            %{id: row.item_step_id, label: row.message || failure_kind, at: row.failed_at}
          end)
      }
    end)
    |> Enum.sort_by(&{&1.stage, &1.subject, &1.title})
  end

  defp site_backoff_groups(now) do
    SiteExtractionPolicy
    |> where([policy], policy.backoff_until > ^now)
    |> order_by([policy], asc: policy.site_host)
    |> Repo.all()
    |> Enum.map(fn policy ->
      %{
        id: "site-#{policy.site_host}",
        kind: :site_backoff,
        stage: "extraction",
        title: "Rate limited",
        subject: policy.site_host,
        detail:
          "Backoff until #{DateTime.to_iso8601(policy.backoff_until)} · " <>
            "#{policy.consecutive_rate_limits} consecutive",
        note: "Resumes automatically",
        count: queued_for_host(policy.site_host),
        latest_at: policy.last_rate_limited_at,
        action: {:try_now, policy.site_host},
        action_label: "Try now",
        items: []
      }
    end)
  end

  defp queued_for_host(site_host) do
    PipelineStepAttempt
    |> join(:inner, [attempt], article in Content.Article, on: article.id == attempt.article_id)
    |> where([attempt], attempt.step_type == "extraction" and attempt.status == "queued")
    |> select([_attempt, article], coalesce(article.resolved_url, article.canonical_url))
    |> Repo.all()
    |> Enum.count(&(Content.site_host(&1) == site_host))
  end

  defp feed_fetch_groups do
    InputFeed
    |> where([feed], feed.last_fetch_status == "failed" and feed.enabled == true)
    |> order_by([feed], asc: feed.name)
    |> Repo.all()
    |> Enum.map(fn feed ->
      %{
        id: "feed-#{feed.id}",
        kind: :feed_fetch_failed,
        stage: "fetch",
        title: "Feed fetch failed",
        subject: feed.name,
        detail: latest_fetch_error(feed),
        note: "Retries next cycle",
        count: 1,
        latest_at: feed.last_fetched_at,
        action: {:refetch, feed.id},
        action_label: "Refetch",
        items: []
      }
    end)
  end

  defp latest_fetch_error(feed) do
    Newspaper.Operations.Failure
    |> where([f], f.failure_type == "fetch_input_feed_failed")
    |> where([f], fragment("(?->>'input_feed_id')::bigint = ?", f.related, ^feed.id))
    |> order_by([f], desc: f.id)
    |> limit(1)
    |> Repo.one()
    |> case do
      nil -> nil
      failure -> failure.message
    end
  end

  defp entry_failure_groups do
    @entry_failure_types
    |> Operations.list_unresolved_failures()
    |> Enum.group_by(
      &{&1.failure_type, &1.related["input_feed_id"] || &1.related["generated_feed_id"]}
    )
    |> Enum.map(fn {{failure_type, scope_id}, failures} ->
      latest = hd(failures)

      %{
        id: "entry-#{failure_type}-#{scope_id}",
        kind: :entry_failed,
        stage: entry_stage(failure_type),
        title: NewspaperWeb.AdminLive.Format.failure_type_label(failure_type),
        subject: entry_subject(failure_type, latest),
        detail: latest.message,
        note: "Retried by replaying the stored entry or refetching the feed",
        count: length(failures),
        latest_at: latest.inserted_at,
        action: {:retry_entries, Enum.map(failures, & &1.id)},
        action_label: "Retry #{length(failures)}",
        items:
          Enum.map(failures, fn failure ->
            %{
              id: failure.id,
              label: failure.related["url"] || failure.message,
              at: failure.inserted_at
            }
          end)
      }
    end)
    |> Enum.sort_by(&{&1.stage, &1.subject})
  end

  defp entry_stage("generated_feed_item_create_failed"), do: "publishing"
  defp entry_stage(_failure_type), do: "fetch"

  defp entry_subject("generated_feed_item_create_failed", failure) do
    case failure.related["generated_feed_id"] do
      id when is_integer(id) ->
        (Repo.get(GeneratedFeed, id) || %{title: "Output feed ##{id}"}).title

      _ ->
        "Output feed"
    end
  end

  defp entry_subject(_failure_type, failure) do
    case failure.related["input_feed_id"] do
      id when is_integer(id) -> (Repo.get(InputFeed, id) || %{name: "Input feed ##{id}"}).name
      _ -> "Input feed"
    end
  end

  defp stuck_run_groups(now) do
    Run
    |> where(
      [run],
      run.status == "running" and run.run_type not in ["pipeline_step", "pipeline_batch"]
    )
    |> order_by([run], asc: run.started_at)
    |> Repo.all()
    |> Enum.flat_map(fn run ->
      timeout = Map.get(@stage_timeouts_seconds, run.run_type, 900)
      age = DateTime.diff(now, run.started_at, :second)
      alive? = Operations.run_owner_alive?(run)

      cond do
        age <= timeout ->
          []

        alive? ->
          [stuck_group(run, :slow, age, nil, "Still running")]

        true ->
          [stuck_group(run, :abandoned, age, {:close_run, run.id}, "Close as failed")]
      end
    end)
  end

  defp stuck_group(run, state, age_seconds, action, action_label) do
    %{
      id: "run-#{run.id}",
      kind: :stuck_run,
      stage: "operations",
      title:
        if(state == :abandoned,
          do: "Abandoned #{NewspaperWeb.AdminLive.Format.run_type_label(run.run_type)}",
          else: "Slow #{NewspaperWeb.AdminLive.Format.run_type_label(run.run_type)}"
        ),
      subject: "Run ##{run.id}",
      detail:
        if(state == :abandoned,
          do: "No live owner after #{div(age_seconds, 60)} min",
          else: "Running for #{div(age_seconds, 60)} min with a live owner"
        ),
      note:
        if(state == :abandoned,
          do: "Closing marks it failed; nothing is retried",
          else: "Expected to finish"
        ),
      count: 1,
      latest_at: run.started_at,
      action: action,
      action_label: action_label,
      items: []
    }
  end
end
