# Robustness and Failure Handling

Ways the system can wedge, strand work, or lose visibility. The plan puts
unusual emphasis on visible failures and restart recovery, so these are
first-class findings even where the happy path works.

---

## R-1 — Extraction dispatcher wedges a host permanently if the task never reports back

- **Severity:** high
- **Confidence:** certain (code path), likely (occurrence over time)
- **Location:** `newspaper/lib/newspaper/processing/dispatcher.ex` (`start_next/2`, `handle_cast({:finished, …})`), `newspaper/lib/newspaper/extraction.ex:9-20`

`start_next` marks the host `running?: true` and spawns:

```elixir
Task.Supervisor.start_child(…, fn ->
  result = Extraction.execute_attempt(attempt_id)
  GenServer.cast(__MODULE__, {:finished, site_host, result})
end)
```

The dispatcher never monitors the task. If the task dies before the cast, the
host stays `running?: true` forever; every subsequent attempt for that host
queues behind it until app restart. The `{:finished, …}` cast is the *only*
thing that clears the flag.

The task **can** die before the cast:

- `Extraction.execute_attempt/1` calls `Processing.get_attempt!/1` **outside**
  its `try/rescue`. If the attempt row is gone — e.g., the article was deleted
  (attempts cascade via `article_id … on_delete: :delete_all`) between enqueue
  and execution — `get_attempt!` raises and the task dies uncaught.
- `fail_execution/4` itself performs DB writes; a DB outage inside the rescue
  path raises again, killing the task after the rescue.

The digestion dispatcher has the identical shape
(`digestion/dispatcher.ex`), and because it is one global serial queue, a
single lost task wedges **all** digestion, not just one host.

**Fix direction:** `Process.monitor` the task and treat `:DOWN` without a
prior `{:finished, …}` as a finished-with-error; move `get_attempt!` inside
the rescue boundary; consider a watchdog that clears `running?` after
`timeout_ms + margin`.

---

## R-2 — Attempts for articles with unusable URLs are silently stranded in `queued`

- **Severity:** high
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/processing.ex:1448-1461` (`dispatch/2`), `newspaper/lib/newspaper/processing/dispatcher.ex` (`enqueue/3` fallback clause, `enqueue_attempt/4` nil clause)

`dispatch` computes `Content.site_host(resolved_url || canonical_url)`. If the
article has no URL or an unparseable one, `site_host` returns `nil` and both
the public `enqueue/3` guard clause and the internal
`enqueue_attempt(state, _attempt_id, nil, _priority)` clause silently drop the
attempt. The `pipeline_step_attempts` row stays `queued` forever; startup
recovery re-lists it and drops it again. Nothing surfaces this to the
operator — the item just shows "queued" indefinitely in Processing.

**Fix direction:** fail the attempt immediately with a visible, non-retryable
failure ("article has no usable URL") instead of dropping the enqueue; that
also matches the existing `run_url_candidates` fallback error
(`:no_usable_article_url`) which only fires when the dispatcher *does* run the
attempt.

---

## R-3 — Extraction crash paths leave the per-attempt run record open forever

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/extraction.ex:9-20, 270-288`

`execute_attempt`'s `rescue`/`catch` call `fail_execution(attempt, …)` without
the `run` argument, so the `pipeline_step` run created inside
`do_execute_attempt` is never finished and stays `running` permanently. The
restart recovery in `requeue_interrupted_attempts` closes runs only for
attempts that were themselves stuck in `running` status — here the attempt is
marked `failed`, so its zombie run is never cleaned up. These accumulate as
phantom "running" rows in operational views.

**Fix direction:** track the run in the rescue scope (create it before the
`try`, or look up the open run for the attempt in `fail_execution`).

---

## R-4 — Worker timeout does not kill the worker process; no init reaper in the container

- **Severity:** medium
- **Confidence:** likely
- **Location:** `newspaper/lib/newspaper/extraction/command_worker.ex` (`receive_output_until/3`, `close_port/1`), `Dockerfile` (commented-out tini)

On timeout the port is closed, but closing an Erlang port does not kill the
spawned OS process — it only closes stdio. The bash wrapper `exec`s the worker,
so the node (or headless-Chromium) process keeps running until it happens to
write to the closed stdout. A hung Playwright/Chromium render can outlive the
timeout indefinitely, and repeated timeouts accumulate orphaned browser
processes in the app container. The Dockerfile explicitly leaves the tini
init-process suggestion commented out, so nothing reaps zombies either
(the BEAM runs as PID 1).

**Fix direction:** wrap the worker with a killer (`bash -c 'worker & …'` with
a watchdog, or spawn via a small supervisor script that kills the process
group on stdin close), have the workers implement their own hard deadline
(the JS workers do abort *fetches* on timeout, but Playwright launch/goto
hangs outside that window are only bounded by Playwright's own timeouts), and
enable an init process (`init: true` in compose, or tini) so defunct processes
are reaped.

---

## R-5 — Interrupted fetch/backfill/re-render runs are never recovered

- **Severity:** medium
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex` (all `start_run` call sites); recovery exists only in `processing.ex:696-737` and `batch_dispatcher.ex`

Restart recovery covers pipeline step attempts and `pipeline_batch` runs, per
plan. But `fetch_all`, `fetch_input_feed`, `process_intake_group`,
`process_input_feed`, `backfill_output_feed`, and `rerender_output_feed` runs
that are interrupted (deploy, crash) stay `running` forever with no operator
affordance to close or retry them. Re-render is user-visible state ("Re-render
started" flash + snapshots half-updated) with no resumption.

**Fix direction:** at startup, close any non-attempt run still `running` as
`failed`/`interrupted` (they are all idempotent to re-execute manually), or
adopt the same requeue pattern used for attempts where re-execution is safe.

---

## R-6 — LiveView-initiated re-render/backfill are fire-and-forget with partial error visibility

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper_web/live/admin_live/output_feed.ex:94-109, 638-653`, `admin_live/intake.ex:181-191`, `admin_live/dashboard.ex` (`retry_failure`)

Backfill and per-feed fetch use `Task.Supervisor.start_child` with no result
handling: if the task crashes (see C-4), the only traces are a crash log and a
stuck run. Re-render uses `async_nolink` and does surface completion via the
socket, but if the user navigates away the result is dropped (run record still
records it — acceptable, but worth knowing). `retry_failure` from the
dashboard likewise reports "Retry started" regardless of what the retry then
does.

This conflicts mildly with `pipeline.md`: "Enrollment belongs to an
application-supervised dispatcher rather than the requesting LiveView or HTTP
process." Batch processing honors that (BatchDispatcher); fetch, backfill, and
re-render do not — they are supervised as tasks but owned by no recoverable
process.

---

## R-7 — Scheduler swallow-and-default on settings read

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline/scheduler.ex` (`configured_interval_ms/0`)

```elixir
defp configured_interval_ms do
  Operations.get_settings().fetch_interval_minutes * 60_000
rescue
  _ -> @default_interval_ms
end
```

A broken settings row (or DB hiccup) silently falls back to the default
interval; combined with `Operations.get_settings/0` creating a default row on
demand, a transient DB error at the wrong moment could also create duplicate
settings rows (`get_settings` takes the lowest-ID row, so extras are inert but
confusing). Low impact; worth a log line at minimum.

---

## R-8 — `retry_failure` increments the retry counter even when the retry is unsupported

- **Severity:** low
- **Confidence:** certain
- **Location:** `newspaper/lib/newspaper/pipeline.ex:201-211`

`Operations.increment_failure_retry/1` runs before `retry_failure_type/2`
dispatch; a failure type with no retry handler returns
`{:error, :unsupported_failure_type}` but the failure now shows a bumped
`retry_count` and fresh `last_attempted_at`, which misrepresents history. The
existing test ("retrying an unsupported retryable failure records the manual
attempt") pins this as intended behavior — if that was a deliberate decision,
document it; otherwise reorder.
