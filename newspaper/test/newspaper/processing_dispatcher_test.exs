defmodule Newspaper.ProcessingDispatcherTest do
  use Newspaper.DataCase

  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Processing
  alias Newspaper.Processing.{PipelineStepAttempt, PriorityQueue}
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem
  alias Newspaper.Repo

  test "an extraction request without a usable URL fails visibly instead of remaining queued" do
    original = Application.get_env(:newspaper, :processing_dispatcher_enabled)
    Application.put_env(:newspaper, :processing_dispatcher_enabled, true)

    on_exit(fn ->
      Application.put_env(:newspaper, :processing_dispatcher_enabled, original)
    end)

    {_item, attempt} = queued_extraction_attempt!(nil)
    _ = :sys.get_state(Newspaper.Processing.Dispatcher)

    attempt = Repo.get!(PipelineStepAttempt, attempt.id)
    assert attempt.status == "failed"
    assert attempt.failure_kind == "invalid_url"
    refute attempt.retryable
    assert attempt.error_message == "Article has no usable extraction URL"
  end

  test "a dead extraction task releases its host and fails the attempt visibly" do
    {_item, attempt} = queued_extraction_attempt!("https://example.com/article")
    ref = make_ref()

    state = %{
      hosts: %{
        "example.com" => %{
          queue: PriorityQueue.new(),
          running?: true,
          timer: nil,
          timer_token: nil,
          task_pid: self(),
          task_ref: ref,
          attempt_id: attempt.id
        }
      }
    }

    assert {:noreply, recovered_state} =
             Newspaper.Processing.Dispatcher.handle_info(
               {:DOWN, ref, :process, self(), :killed},
               state
             )

    host_state = recovered_state.hosts["example.com"]
    refute host_state.running?
    assert host_state.task_ref == nil

    attempt = Repo.get!(PipelineStepAttempt, attempt.id)
    assert attempt.status == "failed"
    assert attempt.failure_kind == "dispatcher_task_exit"
  end

  defp queued_extraction_attempt!(url) do
    {:ok, input_feed} =
      Intake.create_input_feed(%{
        name: "Example Feed",
        url: "https://example.com/feed.xml"
      })

    {:ok, _raw_item} =
      Intake.upsert_raw_item(input_feed, %{
        feed_guid: "example-#{System.unique_integer([:positive])}",
        url: url,
        title: "An article",
        discovered_at: ~U[2026-07-24 12:00:00Z]
      })

    assert {:ok, _run} = Pipeline.process_input_feed(input_feed.id, "test")

    {:ok, output_feed} =
      Publishing.create_generated_feed(%{
        "title" => "Example",
        "input_feed_ids" => [input_feed.id]
      })

    assert {:ok, _step} = Processing.create_extraction_step(output_feed)
    assert {:ok, _run} = Pipeline.backfill_output_feed(output_feed.id, "test")

    {Repo.one!(GeneratedFeedItem), Repo.one!(PipelineStepAttempt)}
  end
end
