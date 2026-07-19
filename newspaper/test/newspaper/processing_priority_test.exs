defmodule Newspaper.ProcessingPriorityTest do
  use Newspaper.DataCase

  alias Newspaper.Content.Article
  alias Newspaper.Operations
  alias Newspaper.Processing
  alias Newspaper.Processing.{PipelineStepAttempt, PriorityQueue}
  alias Newspaper.Repo

  test "foreground work is listed ahead of older bulk work" do
    bulk_article = article!("bulk")
    foreground_article = article!("foreground")

    assert {:ok, batch} =
             Operations.start_run("pipeline_batch", "test", %{
               "generated_feed_id" => 1,
               "step_type" => "digestion"
             })

    bulk_attempt = attempt!(bulk_article, batch.id)
    foreground_attempt = attempt!(foreground_article)

    assert Processing.list_queued_attempts("digestion")
           |> Enum.map(& &1.id) == [foreground_attempt.id, bulk_attempt.id]
  end

  test "foreground work is popped ahead of previously queued bulk work" do
    queue =
      PriorityQueue.new()
      |> PriorityQueue.put(10, :bulk)
      |> PriorityQueue.put(20, :foreground)

    assert {{:value, 20}, queue} = PriorityQueue.pop(queue)
    assert {{:value, 10}, queue} = PriorityQueue.pop(queue)
    assert {:empty, _queue} = PriorityQueue.pop(queue)
  end

  defp article!(suffix) do
    %Article{}
    |> Article.changeset(%{
      canonical_url: "https://example.com/#{suffix}",
      title: "Article #{suffix}",
      dedupe_scope: "test",
      dedupe_key: "priority:#{suffix}"
    })
    |> Repo.insert!()
  end

  defp attempt!(article, batch_run_id \\ nil) do
    changeset =
      PipelineStepAttempt.changeset(%PipelineStepAttempt{}, %{
        article_id: article.id,
        implementation_key: "digestion.ollama.article_digest",
        step_type: "digestion",
        status: "queued",
        input_snapshot: %{},
        output_snapshot: %{},
        debug_metadata: %{}
      })

    changeset =
      if batch_run_id,
        do: Ecto.Changeset.put_change(changeset, :batch_run_id, batch_run_id),
        else: changeset

    Repo.insert!(changeset)
  end
end
