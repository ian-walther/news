defmodule Newspaper.Operations.Attention do
  @moduledoc """
  The derived attention inbox: what currently needs an operator, grouped by
  cause, each group with one correct action. Nothing here is filed or
  acknowledged — fixing the cause makes the group disappear.

  `count/1` is a cheap SQL projection used for badges; `groups/1` builds the
  inbox from aggregates only (no per-item rows); `group_items/2` loads a
  bounded page of one group's items on demand. Group actions select their
  members at execution time, so nothing is materialized just to render a
  collapsed group (audit IMP-18, IMP-19).

  Group kinds:

  - `:step_failed` — item steps in `failed`, by step, failure kind, and feed
  - `:site_backoff` — hosts whose extraction backoff is still in the future
  - `:feed_fetch_failed` — input feeds whose last fetch failed
  - `:entry_failed` — unresolved pre-pipeline failure records (ingestion,
    processing, publication) and per-item re-render failures
  - `:stuck_run` — running operations with no live owner past their stage
    timeout (`:abandoned`) or a live owner running longer than expected
    (`:slow`, informational)
  """

  import Ecto.Query

  alias Newspaper.Content
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Intake.InputFeed
  alias Newspaper.Operations
  alias Newspaper.Operations.{Failure, Run}
  alias Newspaper.Processing
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineStepAttempt, Registry}
  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Repo

  @entry_failure_types ~w(raw_item_ingestion_failed raw_item_processing_failed generated_feed_item_create_failed generated_feed_item_render_failed)
  @replayable_types ~w(raw_item_ingestion_failed raw_item_processing_failed generated_feed_item_create_failed)

  def entry_failure_types, do: @entry_failure_types

  def groups(now \\ DateTime.utc_now(:second)) do
    step_failure_groups() ++
      site_backoff_groups(now) ++
      feed_fetch_groups() ++
      entry_failure_groups() ++
      stuck_run_groups(now)
  end

  @doc "Number of actionable groups, from aggregate queries only."
  def count(now \\ DateTime.utc_now(:second)) do
    step_failure_group_count() +
      site_backoff_count(now) +
      feed_fetch_failed_count() +
      entry_failure_group_count() +
      abandoned_run_count(now)
  end

  @items_page 100

  @doc "Executes a group's action. Returns `{:ok, message}` or `{:error, reason}`."
  def perform({:retry_items, feed_id, step_type, item_step_ids}) do
    case Processing.start_feed_batch(feed_id, "manual", step_type,
           selection: {:items, item_step_ids}
         ) do
      {:ok, _batch} -> {:ok, "#{Registry.step_label(step_type)} retry batch started"}
      {:error, reason} -> {:error, reason}
    end
  end

  # Whole-group retry selects the group's current members at execution time.
  def perform({:retry_step_group, feed_id, step_type, failure_kind}) do
    ids =
      failed_step_query()
      |> where([_item_step, _item, feed], feed.id == ^feed_id)
      |> where([item_step], item_step.step_type == ^step_type)
      |> where(
        [_item_step, _item, _feed, attempt],
        coalesce(attempt.failure_kind, "failed") == ^failure_kind
      )
      |> select([item_step], item_step.id)
      |> Repo.all()

    perform({:retry_items, feed_id, step_type, ids})
  end

  def perform({:retry_entry_group, failure_type, scope_id}) do
    ids =
      unresolved_entry_query()
      |> where([f], f.failure_type == ^failure_type)
      |> where(
        [f],
        fragment(
          "coalesce(?->>'input_feed_id', ?->>'generated_feed_id') = ?",
          f.related,
          f.related,
          ^to_string(scope_id)
        )
      )
      |> select([f], f.id)
      |> Repo.all()

    perform({:retry_entries, ids})
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
    case Newspaper.Pipeline.start_retry_entry_failures(failure_ids) do
      {:ok, count} ->
        {:ok,
         "Retrying #{count} #{if count == 1, do: "entry", else: "entries"} in the background; " <>
           "the result is recorded under History"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def perform({:rerender, feed_id}) do
    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Newspaper.Pipeline.rerender_output_feed(feed_id, "manual")
    end)

    {:ok, "Refreshing RSS output in the background"}
  end

  def perform({:close_run, run_id}) do
    case Operations.close_run_as_failed(run_id) do
      {:ok, _run} -> {:ok, "Run ##{run_id} closed as failed"}
      {:error, reason} -> {:error, {:close_run, reason}}
    end
  end

  def perform(nil), do: {:error, :no_action}

  # --- step failures --------------------------------------------------------

  defp failed_step_query do
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
  end

  defp step_failure_group_count do
    failed_step_query()
    |> select([item_step, _item, feed, attempt], %{
      step_type: item_step.step_type,
      kind: coalesce(attempt.failure_kind, "failed"),
      feed_id: feed.id
    })
    |> distinct(true)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  defp step_failure_groups do
    failed_step_query()
    |> group_by([item_step, _item, feed, attempt], [
      item_step.step_type,
      coalesce(attempt.failure_kind, "failed"),
      feed.id,
      feed.title
    ])
    |> select([item_step, _item, feed, attempt], %{
      step_type: item_step.step_type,
      failure_kind: coalesce(attempt.failure_kind, "failed"),
      feed_id: feed.id,
      feed_title: feed.title,
      count: count(item_step.id),
      latest_at: max(item_step.finished_at),
      retryable: fragment("bool_or(coalesce(?, false))", attempt.retryable),
      latest_item_step_id: max(item_step.id)
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      %{
        id: "step-#{row.step_type}-#{row.failure_kind}-#{row.feed_id}",
        kind: :step_failed,
        stage: row.step_type,
        title:
          NewspaperWeb.AdminLive.Format.failure_type_label("pipeline_step_#{row.failure_kind}"),
        subject: row.feed_title,
        detail: latest_step_message(row.latest_item_step_id),
        note: if(row.retryable, do: "Retryable", else: "Not retried automatically"),
        count: row.count,
        latest_at: row.latest_at,
        feed_id: row.feed_id,
        action: {:retry_step_group, row.feed_id, row.step_type, row.failure_kind},
        action_label: "Retry #{row.count}",
        items_key: {:step_failed, row.feed_id, row.step_type, row.failure_kind}
      }
    end)
    |> Enum.sort_by(&{&1.stage, &1.subject, &1.title})
  end

  defp latest_step_message(item_step_id) do
    GeneratedFeedItemStep
    |> join(:left, [item_step], attempt in PipelineStepAttempt,
      on: attempt.id == item_step.latest_attempt_id
    )
    |> where([item_step], item_step.id == ^item_step_id)
    |> select([item_step, attempt], coalesce(attempt.error_message, item_step.error_message))
    |> Repo.one()
  end

  @doc """
  A bounded page of one group's items, loaded on demand. Returns
  `%{items: [...], total: n, more?: boolean}`.
  """
  def group_items(group, page \\ 1)

  def group_items(%{items_key: {:step_failed, feed_id, step_type, failure_kind}}, page) do
    query =
      failed_step_query()
      |> where([_item_step, _item, feed], feed.id == ^feed_id)
      |> where([item_step], item_step.step_type == ^step_type)
      |> where(
        [_item_step, _item, _feed, attempt],
        coalesce(attempt.failure_kind, "failed") == ^failure_kind
      )

    total = Repo.aggregate(query, :count, :id)

    items =
      query
      |> join(:inner, [_item_step, item], article in Content.Article,
        on: article.id == item.article_id
      )
      |> order_by([item_step], desc_nulls_last: item_step.finished_at, desc: item_step.id)
      |> offset(^((page - 1) * @items_page))
      |> limit(@items_page)
      |> select([item_step, _item, _feed, attempt, article], %{
        id: item_step.id,
        label: coalesce(article.title, coalesce(article.resolved_url, article.canonical_url)),
        detail: coalesce(attempt.error_message, item_step.error_message),
        at: item_step.finished_at,
        article_id: article.id,
        article_guid: article.guid,
        attempt_id: attempt.id
      })
      |> Repo.all()
      |> Enum.map(fn item ->
        Map.merge(item, %{
          feed_id: feed_id,
          stage: step_type,
          action: {:retry_items, feed_id, step_type, [item.id]}
        })
      end)

    %{items: items, total: total, more?: page * @items_page < total}
  end

  def group_items(%{items_key: {:entry_failed, failure_type, scope_id}}, page) do
    query =
      unresolved_entry_query()
      |> where([f], f.failure_type == ^failure_type)
      |> where(
        [f],
        fragment(
          "coalesce(?->>'input_feed_id', ?->>'generated_feed_id') = ?",
          f.related,
          f.related,
          ^to_string(scope_id)
        )
      )

    total = Repo.aggregate(query, :count, :id)

    items =
      query
      |> order_by([f], desc: f.inserted_at, desc: f.id)
      |> offset(^((page - 1) * @items_page))
      |> limit(@items_page)
      |> Repo.all()
      |> Enum.map(fn failure ->
        %{
          id: failure.id,
          label: failure.related["url"] || failure.message,
          detail: failure.message,
          at: failure.inserted_at,
          article_id: failure.related["article_id"],
          article_guid: nil,
          attempt_id: nil,
          feed_id: nil,
          stage: entry_stage(failure_type),
          action: {:retry_entries, [failure.id]}
        }
      end)

    %{items: items, total: total, more?: page * @items_page < total}
  end

  def group_items(_group, _page), do: %{items: [], total: 0, more?: false}

  # --- site backoff ---------------------------------------------------------

  defp site_backoff_count(now) do
    SiteExtractionPolicy
    |> where([policy], policy.backoff_until > ^now)
    |> Repo.aggregate(:count)
  end

  defp site_backoff_groups(now) do
    queued_by_host = queued_extraction_hosts()

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
        count: Map.get(queued_by_host, policy.site_host, 0),
        latest_at: policy.last_rate_limited_at,
        feed_id: nil,
        action: {:try_now, policy.site_host},
        action_label: "Try now",
        items_key: nil
      }
    end)
  end

  defp queued_extraction_hosts do
    PipelineStepAttempt
    |> join(:inner, [attempt], article in Content.Article, on: article.id == attempt.article_id)
    |> where([attempt], attempt.step_type == "extraction" and attempt.status == "queued")
    |> select([_attempt, article], coalesce(article.resolved_url, article.canonical_url))
    |> Repo.all()
    |> Enum.map(&Content.site_host/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
  end

  # --- feed fetch -----------------------------------------------------------

  defp feed_fetch_failed_count do
    InputFeed
    |> where([feed], feed.last_fetch_status == "failed" and feed.enabled == true)
    |> Repo.aggregate(:count)
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
        feed_id: nil,
        action: {:refetch, feed.id},
        action_label: "Refetch",
        items_key: nil
      }
    end)
  end

  defp latest_fetch_error(feed) do
    Failure
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

  # --- entry failures -------------------------------------------------------

  defp entry_failure_group_count do
    Failure
    |> where([f], f.failure_type in ^@entry_failure_types and is_nil(f.resolved_at))
    |> select([f], %{
      type: f.failure_type,
      scope:
        coalesce(
          fragment("?->>'input_feed_id'", f.related),
          fragment("?->>'generated_feed_id'", f.related)
        )
    })
    |> distinct(true)
    |> subquery()
    |> Repo.aggregate(:count)
  end

  defp unresolved_entry_query do
    Failure
    |> where([f], f.failure_type in ^@entry_failure_types and is_nil(f.resolved_at))
  end

  defp entry_failure_groups do
    unresolved_entry_query()
    |> group_by([f], [
      f.failure_type,
      fragment("coalesce(?->>'input_feed_id', ?->>'generated_feed_id')", f.related, f.related)
    ])
    |> select([f], %{
      failure_type: f.failure_type,
      scope:
        fragment("coalesce(?->>'input_feed_id', ?->>'generated_feed_id')", f.related, f.related),
      count: count(f.id),
      latest_id: max(f.id)
    })
    |> Repo.all()
    |> Enum.map(fn row ->
      latest = Repo.get!(Failure, row.latest_id)
      scope_id = parse_scope(row.scope)
      failure_type = row.failure_type

      %{
        id: "entry-#{failure_type}-#{scope_id}",
        kind: :entry_failed,
        stage: entry_stage(failure_type),
        title: NewspaperWeb.AdminLive.Format.failure_type_label(failure_type),
        subject: entry_subject(failure_type, latest),
        detail: latest.message,
        note: entry_note(failure_type),
        count: row.count,
        latest_at: latest.inserted_at,
        feed_id: if(failure_type == "generated_feed_item_render_failed", do: scope_id),
        action: entry_action(failure_type, scope_id),
        action_label: entry_action_label(failure_type, row.count),
        items_key: {:entry_failed, failure_type, scope_id}
      }
    end)
    |> Enum.sort_by(&{&1.stage, &1.subject})
  end

  defp parse_scope(nil), do: nil

  defp parse_scope(scope) when is_binary(scope) do
    case Integer.parse(scope) do
      {id, ""} -> id
      _ -> scope
    end
  end

  defp entry_stage("generated_feed_item_create_failed"), do: "publishing"
  defp entry_stage("generated_feed_item_render_failed"), do: "publishing"
  defp entry_stage(_failure_type), do: "fetch"

  defp entry_note("generated_feed_item_render_failed"),
    do: "Refresh RSS output re-renders every item of the feed"

  defp entry_note(_failure_type),
    do: "Replays the stored entry, or refetches the source once, in the background"

  defp entry_action("generated_feed_item_render_failed", feed_id) when is_integer(feed_id),
    do: {:rerender, feed_id}

  defp entry_action(type, scope_id) when type in @replayable_types,
    do: {:retry_entry_group, type, scope_id}

  defp entry_action(_type, _scope_id), do: nil

  defp entry_action_label("generated_feed_item_render_failed", _count), do: "Refresh RSS output"
  defp entry_action_label(_type, count), do: "Retry #{count}"

  defp entry_subject(type, failure)
       when type in ["generated_feed_item_create_failed", "generated_feed_item_render_failed"] do
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

  # --- stuck runs -----------------------------------------------------------

  defp running_operations do
    Run
    |> where(
      [run],
      run.status == "running" and run.run_type not in ["pipeline_step", "pipeline_batch"]
    )
    |> order_by([run], asc: run.started_at)
    |> Repo.all()
  end

  defp abandoned_run_count(now) do
    Enum.count(running_operations(), &(Operations.run_liveness(&1, now) == :abandoned))
  end

  defp stuck_run_groups(now) do
    Enum.flat_map(running_operations(), fn run ->
      age = DateTime.diff(now, run.started_at, :second)

      case Operations.run_liveness(run, now) do
        :active -> []
        :slow -> [stuck_group(run, :slow, age, nil, "Still running")]
        :abandoned -> [stuck_group(run, :abandoned, age, {:close_run, run.id}, "Close as failed")]
        :finished -> []
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
      feed_id: nil,
      action: action,
      action_label: action_label,
      items_key: nil
    }
  end
end
