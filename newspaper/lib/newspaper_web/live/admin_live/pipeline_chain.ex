defmodule NewspaperWeb.AdminLive.PipelineChain do
  @moduledoc """
  Renders one feed's processing chain: its steps in canonical order, each
  link carrying the enabled toggle, coverage, and the step's actions. Every
  link is the same component regardless of step type; the registry decides
  what appears.
  """

  use NewspaperWeb, :html

  alias Newspaper.Processing
  alias NewspaperWeb.AdminLive.Format

  attr :entry, :map, required: true
  attr :settings, :map, required: true

  def feed_chain(assigns) do
    ~H"""
    <div
      id={"pipeline-feed-#{@entry.feed.id}"}
      class="grid gap-4 py-5 lg:grid-cols-[11rem_minmax(0,1fr)] lg:items-start"
    >
      <div class="min-w-0">
        <.link navigate={~p"/output-feeds/#{@entry.feed.id}"} class="font-medium hover:underline">
          {@entry.feed.title}
        </.link>
        <p class="mt-1 text-xs text-base-content/55">
          {@entry.item_count} {if @entry.item_count == 1, do: "item", else: "items"}
          <span :if={@entry.held > 0} class="text-warning">· {@entry.held} held</span>
        </p>
      </div>
      <div class="flex flex-wrap items-center gap-2">
        <%= for {link, index} <- Enum.with_index(@entry.steps) do %>
          <.icon :if={index > 0} name="hero-arrow-right" class="size-4 shrink-0 text-base-content/40" />
          <.chain_link feed={@entry.feed} link={link} settings={@settings} />
        <% end %>
        <span
          :if={@entry.steps != [] and @entry.available_step_types != []}
          class="text-base-content/30"
        >
          <.icon name="hero-arrow-right" class="size-4 shrink-0" />
        </span>
        <button
          :for={step_type <- @entry.available_step_types}
          id={"add-step-#{@entry.feed.id}-#{step_type}"}
          type="button"
          class="btn btn-sm btn-ghost border border-dashed border-base-300"
          phx-click="add_step"
          phx-value-feed-id={@entry.feed.id}
          phx-value-step-type={step_type}
          title={"Add #{String.downcase(Processing.Registry.step_label(step_type))} to this feed's chain"}
        >
          <.icon name="hero-plus" class="size-4" /> {Processing.Registry.step_label(step_type)}
        </button>
        <p
          :if={@entry.steps == [] and @entry.available_step_types == []}
          class="text-sm text-base-content/50"
        >
          No steps can be added.
        </p>
      </div>
    </div>
    """
  end

  attr :feed, :map, required: true
  attr :link, :map, required: true
  attr :settings, :map, required: true

  def chain_link(assigns) do
    assigns =
      assigns
      |> assign(:run_reason, run_existing_reason(assigns.link, assigns.settings))
      |> assign(:retry_reason, retry_failed_reason(assigns.link, assigns.settings))
      |> assign(:progress, active_batch_progress(assigns.link))

    ~H"""
    <div
      id={"chain-link-#{@feed.id}-#{@link.step_type}"}
      class={["min-w-56 border px-3 py-2", link_tone(@link)]}
      data-status={link_state(@link)}
    >
      <div class="flex items-center justify-between gap-3">
        <label class="flex cursor-pointer items-center gap-2">
          <span class="text-sm font-semibold">{@link.label}</span>
          <input
            id={"toggle-step-#{@feed.id}-#{@link.step_type}"}
            type="checkbox"
            class="toggle toggle-xs toggle-success"
            checked={@link.step.enabled}
            phx-click="toggle_step"
            phx-value-step-id={@link.step.id}
            aria-label={"#{@link.label} enabled for future articles"}
          />
        </label>
        <details id={"chain-menu-#{@feed.id}-#{@link.step_type}"} class="dropdown dropdown-end">
          <summary class="btn btn-ghost btn-xs btn-square" aria-label={"Actions for #{@link.label}"}>
            <.icon name="hero-ellipsis-horizontal" class="size-4" />
          </summary>
          <ul class="menu dropdown-content z-10 w-72 border border-base-300 bg-base-100 p-1 text-sm shadow">
            <li>
              <button
                id={"run-existing-#{@feed.id}-#{@link.step_type}"}
                type="button"
                phx-click="run_existing"
                phx-value-feed-id={@feed.id}
                phx-value-step-type={@link.step_type}
                phx-disable-with="Queueing..."
                disabled={not is_nil(@run_reason)}
                title={@run_reason}
              >
                {run_existing_label(@link)}
              </button>
            </li>
            <li>
              <button
                id={"retry-failed-#{@feed.id}-#{@link.step_type}"}
                type="button"
                phx-click="retry_failed"
                phx-value-feed-id={@feed.id}
                phx-value-step-type={@link.step_type}
                phx-disable-with="Queueing..."
                disabled={not is_nil(@retry_reason)}
                title={@retry_reason}
              >
                {retry_failed_label(@link)}
              </button>
            </li>
            <li>
              <button
                id={"remove-step-#{@feed.id}-#{@link.step_type}"}
                type="button"
                class="text-error"
                phx-click="remove_step"
                phx-value-step-id={@link.step.id}
                data-confirm={"Remove #{String.downcase(@link.label)} from this feed? Item history is kept."}
              >
                Remove step
              </button>
            </li>
          </ul>
        </details>
      </div>
      <p class="mt-1 text-xs text-base-content/65">{Format.coverage_label(@link.counts)}</p>
      <p :if={@progress} class="mt-1 text-xs font-medium tabular-nums">
        {Format.progress_summary(@progress)}
      </p>
    </div>
    """
  end

  defp link_state(%{step: %{enabled: false}}), do: "disabled"
  defp link_state(%{counts: %{failed: failed}}) when failed > 0, do: "failed"
  defp link_state(%{counts: %{queued: q, running: r}}) when q + r > 0, do: "processing"
  defp link_state(%{counts: %{blocked: blocked}}) when blocked > 0, do: "waiting"
  defp link_state(_link), do: "ready"

  defp link_tone(link) do
    case link_state(link) do
      "disabled" -> "border-base-300 bg-base-100 text-base-content/60"
      "failed" -> "border-error/40 bg-error/5"
      "processing" -> "border-info/40 bg-info/5"
      "waiting" -> "border-warning/40 bg-warning/5"
      "ready" -> "border-success/40 bg-success/5"
    end
  end

  defp active_batch_progress(%{active_batch: nil}), do: nil
  defp active_batch_progress(%{active_batch: batch}), do: Processing.batch_progress(batch)

  defp run_existing_label(link) do
    step = String.downcase(link.label |> String.replace_prefix("Article ", ""))

    case link.counts.not_requested do
      0 -> "Run #{step} on existing items"
      1 -> "Run #{step} on 1 existing item"
      count -> "Run #{step} on #{count} existing items"
    end
  end

  defp retry_failed_label(link) do
    step = String.downcase(link.label |> String.replace_prefix("Article ", ""))

    case link.counts.failed do
      0 -> "Retry failed #{step}"
      1 -> "Retry 1 failed #{step}"
      count -> "Retry #{count} failed #{step}s"
    end
  end

  defp run_existing_reason(link, settings) do
    cond do
      not link.step.enabled ->
        "#{link.label} is disabled for this feed"

      link.step_type == "digestion" and settings.digestion_paused ->
        "Digestion is paused"

      match?(%{related: %{"selection" => "failed"}}, link.active_batch) ->
        "A retry batch for this step is already running"

      not is_nil(link.active_batch) ->
        "This batch is running"

      link.counts.not_requested == 0 and link.counts.blocked > 0 ->
        "Items are waiting for #{waiting_on(link.step_type)}"

      link.counts.not_requested == 0 ->
        "No existing items need this step"

      true ->
        nil
    end
  end

  defp retry_failed_reason(link, settings) do
    cond do
      not link.step.enabled ->
        "#{link.label} is disabled for this feed"

      link.step_type == "digestion" and settings.digestion_paused ->
        "Digestion is paused"

      not is_nil(link.active_batch) ->
        "A batch for this step is already running"

      link.counts.failed == 0 ->
        "No failed items"

      true ->
        nil
    end
  end

  defp waiting_on(step_type) do
    case Processing.Registry.prerequisites(step_type) do
      [] -> "prerequisites"
      types -> Enum.join(types, " and ")
    end
  end
end
