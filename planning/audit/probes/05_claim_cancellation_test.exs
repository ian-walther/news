defmodule Newspaper.ClaimCancellationAuditTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  alias Ecto.Adapters.SQL.Sandbox
  alias Newspaper.{Operations, Processing, Publishing, Repo}
  alias Newspaper.Content.Article
  alias Newspaper.Operations.Run
  alias Newspaper.Publishing.{GeneratedFeed, GeneratedFeedItem}
  alias Newspaper.Processing.{GeneratedFeedItemStep, PipelineBatchMember, PipelineStepAttempt}

  test "IMP-06A cancellation preserves a worker claim that wins after its member snapshot" do
    assert String.starts_with?(Repo.config()[:database], "newspaper_test")
    sup = start_supervised!({Task.Supervisor, []})
    parent = self()
    token = make_ref()

    # These fixtures are committed only in the local test database so each
    # task uses a genuinely independent PostgreSQL connection and row locks.
    {feed, article, item, batch, attempt} = Sandbox.unboxed_run(Repo, &fixture!/0)

    on_exit(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from(f in GeneratedFeed, where: f.id == ^feed.id))
        Repo.delete_all(from(a in Article, where: a.id == ^article.id))
        Repo.delete_all(from(r in Run, where: r.id == ^batch.id))
      end)
    end)

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

        claimed? =
          role == :claim and
            String.starts_with?(meta.query, "UPDATE \"generated_feed_item_steps\"")

        if snapshot? or claimed? do
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

      step =
        Repo.get_by!(GeneratedFeedItemStep,
          generated_feed_item_id: item.id,
          step_type: "extraction"
        )

      assert {result.running, step.status} == {1, "running"}
    end)
  end

  defp fixture! do
    unique = Ecto.UUID.generate()
    now = DateTime.utc_now(:second)
    {:ok, feed} = Publishing.create_generated_feed(%{title: "Audit claim race #{unique}"})

    article =
      %Article{}
      |> Article.changeset(%{
        canonical_url: "https://www.theautopian.com/claim-race-#{unique}/",
        resolved_url: "https://www.theautopian.com/claim-race-#{unique}/",
        title: "A manual transmission story",
        dedupe_scope: "audit-#{unique}",
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

    step =
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "extraction"
      )

    {:ok, batch} =
      Operations.start_run("pipeline_batch", "audit", %{
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
