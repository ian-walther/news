defmodule Newspaper.OperationsRecoveryTest do
  use Newspaper.DataCase

  alias Newspaper.Operations

  test "startup recovery closes interrupted operation runs but leaves recoverable batches alone" do
    assert {:ok, fetch_run} = Operations.start_run("fetch_input_feed", "scheduled")
    assert {:ok, batch_run} = Operations.start_run("pipeline_batch", "manual")
    assert {:ok, attempt_run} = Operations.start_run("pipeline_step", "pipeline")

    assert Operations.fail_interrupted_operation_runs() >= 1

    fetch_run = Operations.get_run!(fetch_run.id)
    assert fetch_run.status == "failed"
    assert fetch_run.finished_at
    assert fetch_run.error_summary == "Application restarted while run was in progress"

    assert Operations.get_run!(batch_run.id).status == "running"
    assert Operations.get_run!(attempt_run.id).status == "running"
  end
end
