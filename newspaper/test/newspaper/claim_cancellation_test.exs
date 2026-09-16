defmodule Newspaper.ClaimCancellationTest do
  @moduledoc """
  A worker claim and a cancellation on **independent database connections**
  (audit IMP-06A). Sandbox transactions cannot exercise this, so the fixture
  is committed to the test database and removed afterwards.
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Newspaper.{Operations, Processing, Publishing, Repo}
  alias Newspaper.Content.Article
  alias Newspaper.Operations.Run
  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineBatchMember, PipelineStepAttempt}

  setup do
    assert String.starts_with?(Repo.config()[:database], "newspaper_test")
    {feed, article, item, batch, attempt} = Sandbox.unboxed_run(Repo, &fixture!/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(f in GeneratedFeed, where: f.id == ^feed.id))
        Repo.delete_all(from(a in Article, where: a.id == ^article.id))
        Repo.delete_all(from(r in Run, where: r.id == ^batch.id))
      end)
    end)

    %{item: item, batch: batch, attempt: attempt}
  end

  test "a claim that commits after cancellation's snapshot keeps its item running", ctx do
    %{item: item, batch: batch, attempt: attempt} = ctx
    sup = start_supervised!({Task.Supervisor, []})
    token = barrier!(self())

    cancel =
      Task.Supervisor.async(sup, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(token, :cancel)
          Processing.cancel_feed_batch(batch.id)
        end)
      end)

    assert_receive {:barrier, :cancel, cancel_pid}, 2_000

    claim =
      Task.Supervisor.async(sup, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(token, :claim)
          Processing.mark_attempt_running(attempt)
        end)
      end)

    assert_receive {:barrier, :claim, claim_pid}, 2_000
    send(cancel_pid, {:continue, token})
    {:ok, result} = Task.await(cancel)
    send(claim_pid, {:continue, token})
    assert {:ok, %{status: "running"}} = Task.await(claim)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(PipelineStepAttempt, attempt.id).status == "running"
      step = step!(item)
      assert {result.running, step.status} == {1, "running"}
      [member] = Repo.all(from m in PipelineBatchMember, where: m.batch_run_id == ^batch.id)
      assert member.outcome == nil
      assert Operations.get_run!(batch.id).status == "running"

      # The running work finishes normally and settles the cancelled batch.
      {:ok, _} =
        Processing.finish_attempt(Repo.get!(PipelineStepAttempt, attempt.id), "succeeded")

      assert step!(item).status == "succeeded"
      assert Operations.get_run!(batch.id).status == "cancelled"
      assert Operations.get_run!(batch.id).summary_counts["succeeded"] == 1
    end)
  end

  test "a claim that arrives while cancellation holds the attempt lock finds it withdrawn", ctx do
    %{item: item, batch: batch, attempt: attempt} = ctx
    sup = start_supervised!({Task.Supervisor, []})
    token = barrier!(self())

    cancel =
      Task.Supervisor.async(sup, fn ->
        Sandbox.unboxed_run(Repo, fn ->
          Process.put(token, :cancel_lock)
          Processing.cancel_feed_batch(batch.id)
        end)
      end)

    # Cancellation is paused right after it took the attempt lock.
    assert_receive {:barrier, :cancel_lock, cancel_pid}, 2_000

    claim =
      Task.Supervisor.async(sup, fn ->
        Sandbox.unboxed_run(Repo, fn -> Processing.mark_attempt_running(attempt) end)
      end)

    # The overlapping claim is blocked on that lock, not rejected yet.
    refute_receive {_ref, {:error, :not_queued}}, 300
    send(cancel_pid, {:continue, token})
    {:ok, result} = Task.await(cancel)
    assert {:error, :not_queued} = Task.await(claim)

    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.get!(PipelineStepAttempt, attempt.id).status == "skipped"
      assert {result.running, step!(item).status} == {0, "cancelled"}
      assert Operations.get_run!(batch.id).status == "cancelled"
    end)
  end

  # Pauses cancellation right after its member snapshot and a claim right
  # before its item-step update, so the test controls the interleaving.
  defp barrier!(parent) do
    token = make_ref()

    :telemetry.attach(
      token,
      [:newspaper, :repo, :query],
      fn _, _, meta, _ ->
        role = Process.get(token)

        snapshot? =
          role == :cancel and String.starts_with?(meta.query, "SELECT") and
            String.contains?(meta.query, "FROM \"generated_feed_item_steps\"") and
            String.contains?(meta.query, "\"pipeline_batch_members\"") and
            String.contains?(meta.query, "\"pipeline_step_attempts\"")

        locked? =
          role == :cancel_lock and String.starts_with?(meta.query, "SELECT") and
            String.contains?(meta.query, "FROM \"pipeline_step_attempts\"") and
            String.contains?(meta.query, "FOR UPDATE")

        claimed? =
          role == :claim and
            String.starts_with?(meta.query, "UPDATE \"generated_feed_item_steps\"")

        if snapshot? or locked? or claimed? do
          Process.delete(token)
          send(parent, {:barrier, role, self()})

          receive do
            {:continue, ^token} -> :ok
          after
            5_000 -> raise "claim/cancel barrier timed out"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(token) end)
    token
  end

  defp step!(item),
    do:
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "extraction"
      )

  defp fixture! do
    unique = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)
    {:ok, feed} = Publishing.create_generated_feed(%{title: "Claim race #{unique}"})

    article =
      %Article{}
      |> Article.changeset(%{
        canonical_url: "https://www.theautopian.com/claim-race-#{unique}/",
        resolved_url: "https://www.theautopian.com/claim-race-#{unique}/",
        title: "A manual transmission story",
        dedupe_scope: "test-#{unique}",
        dedupe_key: unique
      })
      |> Repo.insert!()

    item =
      %GeneratedFeedItem{}
      |> GeneratedFeedItem.changeset(%{
        generated_feed_id: feed.id,
        article_id: article.id,
        rendered_at: now,
        first_eligible_at: now,
        last_rendered_at: now
      })
      |> Repo.insert!()

    {:ok, _} = Processing.create_step(feed, "extraction")
    step = step!(item)

    {:ok, batch} =
      Operations.start_run("pipeline_batch", "test", %{
        "generated_feed_id" => feed.id,
        "step_type" => "extraction",
        "selection" => "not_requested"
      })

    Repo.insert!(%PipelineBatchMember{
      batch_run_id: batch.id,
      generated_feed_item_step_id: step.id
    })

    {:ok, [attempt]} = Processing.request_item_step(item, "extraction", batch_run_id: batch.id)
    {feed, article, item, batch, attempt}
  end
end
