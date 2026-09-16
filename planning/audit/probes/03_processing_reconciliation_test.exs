defmodule Newspaper.ProcessingReconciliationAuditTest do
  use NewspaperWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest

  alias Newspaper.{Content, Intake, Operations, Pipeline, Processing, Publishing, Repo}

  alias Newspaper.Processing.{
    BatchDispatcher,
    GeneratedFeedItemStep,
    MembershipBackfill,
    PipelineBatchAttempt,
    PipelineBatchMember,
    PipelineStepAttempt
  }

  test "IMP-06 retry enrollment is not finished by the first fast completion" do
    [feed] = feeds!(2)
    old = batch!(feed)
    for attempt <- Processing.list_attempts_for_batch(old.id), do: fail!(attempt)
    assert Operations.get_run!(old.id).status == "failed"

    # This is the exact durable boundary after create_batch_with_members commits,
    # before the background enrollment task has visited every member.
    batch = frozen_batch!(feed, "failed")
    [first, second] = Publishing.list_items_for_feed(feed)

    {:ok, [attempt]} =
      Processing.request_item_step(first, "extraction", force: true, batch_run_id: batch.id)

    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")

    assert Operations.get_run!(batch.id).status == "running"
    {:ok, _} = Processing.resume_feed_batch(batch.id)
    assert step!(second).status == "queued"
  end

  test "IMP-06 cancellation after the initial guard still prevents a late request" do
    [feed] = feeds!(1)
    batch = frozen_batch!(feed, "not_requested")
    [item] = Publishing.list_items_for_feed(feed)
    parent = self()
    token = make_ref()
    sup = start_supervised!({Task.Supervisor, []})

    :telemetry.attach(
      token,
      [:newspaper, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if Process.get(token) == :armed and meta.params == [batch.id] and
             String.starts_with?(meta.query, "SELECT") and
             String.contains?(meta.query, "FROM \"runs\"") do
          Process.put(token, :passed)
          send(parent, {:past_cancel_check, self(), token})

          receive do
            {:continue, ^token} -> :ok
          after
            5_000 -> raise "audit barrier timed out"
          end
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(token) end)

    task =
      Task.Supervisor.async(sup, fn ->
        Process.put(token, :armed)
        Processing.request_item_step(item, "extraction", batch_run_id: batch.id)
      end)

    assert_receive {:past_cancel_check, worker, ^token}, 2_000
    {:ok, _} = Processing.cancel_feed_batch(batch.id)
    send(worker, {:continue, token})
    _ = Task.await(task)

    assert {step!(item).status, Repo.aggregate(PipelineStepAttempt, :count)} == {"cancelled", 0}
  end

  test "IMP-02 automatic retries of independent work never join a completed batch" do
    [feed] = feeds!(1)
    old = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(old.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, [independent]} = Processing.request_item_step(item, "extraction", force: true)
    assert is_nil(independent.batch_run_id)

    {:ok, independent} =
      Processing.finish_attempt(independent, "failed", %{
        failure_kind: "rate_limited",
        retryable: true
      })

    {:ok, retry} = Processing.schedule_automatic_retry(independent)

    assert {retry.batch_run_id, Enum.map(Processing.list_attempts_for_batch(old.id), & &1.id)} ==
             {nil, [attempt.id]}
  end

  test "IMP-16 shared feed history survives its latest attempt changing" do
    [a, b] = feeds!(1, ["Cars", "Automotive favorites"])
    batch_a = batch!(a)
    _batch_b = batch!(b)
    [attempt] = Processing.list_attempts_for_batch(batch_a.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item_b] = Publishing.list_items_for_feed(b)
    {:ok, [_]} = Processing.request_item_step(item_b, "extraction", force: true)

    assert Enum.any?(
             Processing.list_processing_attempts(["succeeded"], generated_feed_id: b.id),
             &(&1.id == attempt.id)
           )
  end

  test "IMP-20 migration does not rewrite an old success to the latest failure" do
    [feed] = feeds!(1)
    old = batch!(feed)
    [attempt] = Processing.list_attempts_for_batch(old.id)
    {:ok, _} = Processing.finish_attempt(attempt, "succeeded")
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, [independent]} = Processing.request_item_step(item, "extraction", force: true)
    fail!(independent)
    assert Operations.get_run!(old.id).status == "succeeded"
    Repo.delete_all(PipelineBatchMember)
    Repo.delete_all(PipelineBatchAttempt)
    :ok = MembershipBackfill.run_all(Repo)

    member = Repo.get_by!(PipelineBatchMember, batch_run_id: old.id)

    assert {member.outcome, Enum.map(Processing.list_attempts_for_batch(old.id), & &1.id)} ==
             {"succeeded", [attempt.id]}
  end

  test "IMP-19 items held for queued digestion appear through the held-items link", %{conn: conn} do
    [feed] = feeds!(1)

    {:ok, _} =
      Operations.update_settings(Operations.get_settings(), %{ollama_model: "qwen3.6:27b"})

    {:ok, _} = Processing.create_step(feed, "digestion")
    [item] = Publishing.list_items_for_feed(feed)

    Repo.insert!(%Newspaper.Content.ArticleExtraction{
      article_id: item.article_id,
      implementation_key: "extraction.simple_html",
      content_html: "<p>Extracted article body.</p>",
      content_text: "Extracted article body.",
      extracted_at: DateTime.utc_now(:second)
    })

    {:ok, [attempt]} = Processing.request_item_step(item, "digestion")
    assert attempt.status == "queued"
    {:ok, feed} = Publishing.update_generated_feed(feed, %{title_source: "digest"})
    {:ok, _} = Pipeline.rerender_output_feed(feed.id)
    {:ok, view, _} = live(conn, "/processing?tab=pipeline")
    assert has_element?(view, "#held-items-#{feed.id}")

    {:ok, articles, _} =
      view |> element("#held-items-#{feed.id}") |> render_click() |> follow_redirect(conn)

    assert has_element?(articles, "#article-#{item.article_id}")
  end

  test "IMP-21 per-item rerender recovery supports the action exposed by Attention" do
    [feed] = feeds!(1)
    [item] = Publishing.list_items_for_feed(feed)

    {:ok, failure} =
      Operations.create_failure(%{
        failure_type: "generated_feed_item_render_failed",
        message: "A previous render failed",
        related: %{
          "generated_feed_id" => feed.id,
          "generated_feed_item_id" => item.id,
          "article_id" => item.article_id
        }
      })

    {:ok, result} = Pipeline.retry_entry_failures([failure.id])
    assert result.results[failure.id] == :repaired
  end

  test "IMP-12 article history can reopen before a background refresh", %{conn: conn} do
    [feed] = feeds!(1)
    _ = batch!(feed)
    [item] = Publishing.list_items_for_feed(feed)
    {:ok, view, _} = live(conn, "/articles")
    selector = "#article-history-#{item.article_id} summary"
    view |> element(selector) |> render_click()
    view |> element(selector) |> render_click()
    view |> element(selector) |> render_click()
    send(view.pid, :refresh_articles)
    render(view)

    assert has_element?(view, "#article-history-list-#{item.article_id}")
  end

  test "IMP-15 an older single-host backlog cannot hide another host's queue", %{conn: conn} do
    [feed] = feeds!(201)
    [other | _] = Publishing.list_items_for_feed(feed)
    article = Content.get_article!(other.article_id)

    article
    |> Ecto.Changeset.change(
      canonical_url: "https://arstechnica.com/audit-new-host/",
      resolved_url: "https://arstechnica.com/audit-new-host/"
    )
    |> Repo.update!()

    assert Content.site_host(Content.get_article!(article.id).resolved_url) == "arstechnica.com"

    batch = batch!(feed)

    other_attempt =
      Enum.find(
        Processing.list_attempts_for_batch(batch.id),
        &(&1.article_id == other.article_id)
      )

    # Put the other host after the 200-row global stage limit, regardless of
    # generated-item display ordering in fixture setup.
    Repo.update_all(from(a in PipelineStepAttempt, where: a.id == ^other_attempt.id),
      set: [inserted_at: DateTime.add(DateTime.utc_now(:second), 60, :second)]
    )

    {:ok, view, _} = live(conn, "/processing")

    assert has_element?(view, "#queued-extraction-host-arstechnica-com")
  end

  defp fail!(attempt) do
    {:ok, failed} =
      Processing.finish_attempt(attempt, "failed", %{failure_kind: "http_error", retryable: false})

    failed
  end

  defp step!(item),
    do:
      Repo.get_by!(GeneratedFeedItemStep,
        generated_feed_item_id: item.id,
        step_type: "extraction"
      )

  defp batch!(feed) do
    {:ok, batch} = Processing.start_feed_batch(feed.id, "audit", "extraction")
    :ok = BatchDispatcher.await(batch.id)
    batch
  end

  defp frozen_batch!(feed, selection) do
    {:ok, batch} =
      Operations.start_run("pipeline_batch", "audit", %{
        "generated_feed_id" => feed.id,
        "generated_feed_title" => feed.title,
        "step_type" => "extraction",
        "selection" => selection
      })

    for item <- Publishing.list_items_for_feed(feed) do
      Repo.insert!(%PipelineBatchMember{
        batch_run_id: batch.id,
        generated_feed_item_step_id: step!(item).id
      })
    end

    batch
  end

  defp feeds!(count, titles \\ ["Cars"]) do
    {:ok, source} =
      Intake.create_input_feed(%{name: "The Autopian", url: "https://www.theautopian.com/feed/"})

    for n <- 1..count do
      {:ok, _} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "reconciliation-#{n}",
          url: "https://www.theautopian.com/audit-#{n}/",
          title: "An unusual manual transmission: article #{n}",
          discovered_at: ~U[2026-09-14 12:00:00Z]
        })
    end

    {:ok, _} = Pipeline.process_input_feed(source.id, "audit")

    for title <- titles do
      {:ok, feed} =
        Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

      {:ok, _} = Pipeline.backfill_output_feed(feed.id, "audit")
      {:ok, _} = Processing.create_step(feed, "extraction")
      feed
    end
  end
end
