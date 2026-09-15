defmodule NewspaperWeb.AdminLive.FormatTest do
  use ExUnit.Case, async: true

  alias NewspaperWeb.AdminLive.Format

  describe "work_status_label/1" do
    test "maps every pipeline work state to the shared vocabulary" do
      assert Format.work_status_label("not_requested") == "Not requested"
      assert Format.work_status_label("pending") == "Waiting"
      assert Format.work_status_label("blocked") == "Waiting"
      assert Format.work_status_label("queued") == "Queued"
      assert Format.work_status_label("running") == "Running"
      assert Format.work_status_label("succeeded") == "Ready"
      assert Format.work_status_label("failed") == "Failed"
      assert Format.work_status_label("skipped") == "Skipped"
      assert Format.work_status_label("cancelled") == "Cancelled"
    end

    test "falls back to a humanized label for unknown states" do
      assert Format.work_status_label("something_else") == "Something else"
      assert Format.work_status_label(nil) == "Unknown"
    end
  end

  describe "work_status_badge_class/1" do
    test "waiting states share one muted style and terminal states are distinct" do
      assert Format.work_status_badge_class("pending") ==
               Format.work_status_badge_class("blocked")

      assert Format.work_status_badge_class("succeeded") =~ "badge-success"
      assert Format.work_status_badge_class("failed") =~ "badge-error"
      assert Format.work_status_badge_class("cancelled") =~ "badge-neutral"
      assert Format.work_status_badge_class("queued") =~ "badge-warning"
      assert Format.work_status_badge_class("running") =~ "badge-info"
    end
  end

  describe "run_summary/1 for pipeline batches" do
    test "includes queued and running work instead of pretending the batch has not started" do
      summary =
        Format.run_summary(%{
          run_type: "pipeline_batch",
          summary_counts: %{
            "queued" => 159,
            "running" => 1,
            "succeeded" => 185,
            "failed" => 3,
            "skipped" => 0,
            "total" => 348
          }
        })

      assert summary == "185 succeeded · 3 failed · 159 queued · 1 running"
    end

    test "reports an all-queued batch as queued" do
      summary =
        Format.run_summary(%{
          run_type: "pipeline_batch",
          summary_counts: %{"queued" => 348, "running" => 0, "total" => 348}
        })

      assert summary == "348 queued"
    end

    test "says waiting to start only before enrollment has recorded a total" do
      assert Format.run_summary(%{run_type: "pipeline_batch", summary_counts: %{}}) ==
               "Waiting to start"

      assert Format.run_summary(%{run_type: "pipeline_batch", summary_counts: %{"total" => 0}}) ==
               "Nothing to do"
    end
  end

  describe "run_type_label/1" do
    test "uses the operator vocabulary for feed operations" do
      assert Format.run_type_label("backfill_output_feed") == "Add matching articles"
      assert Format.run_type_label("rerender_output_feed") == "Refresh RSS output"
    end
  end

  describe "progress_summary/1" do
    test "renders rate and a rounded estimate when one is defensible" do
      summary =
        Format.progress_summary(%{
          done: 185,
          total: 348,
          remaining: 163,
          per_minute: 4.7,
          eta_seconds: 2081,
          eta_reason: nil
        })

      assert summary == "185 of 348 · 4.7/min · ~35 min left"
    end

    test "explains an absent estimate instead of inventing one" do
      base = %{
        done: 3,
        total: 15,
        remaining: 12,
        per_minute: nil,
        eta_seconds: nil,
        eta_reason: nil
      }

      assert Format.progress_summary(%{base | eta_reason: :paused}) ==
               "3 of 15 · paused"

      assert Format.progress_summary(%{base | eta_reason: :insufficient_samples}) ==
               "3 of 15 · estimating"

      assert Format.progress_summary(%{base | eta_reason: :site_backoff}) ==
               "3 of 15 · waiting on site backoff"

      assert Format.progress_summary(%{base | done: 15, remaining: 0, eta_reason: :complete}) ==
               "15 of 15"

      assert Format.progress_summary(%{base | total: nil, eta_reason: :not_started}) ==
               "Waiting to start"
    end
  end
end
