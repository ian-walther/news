defmodule NewspaperWeb.AdminLive.OutputFeeds do
  use NewspaperWeb, :live_view

  alias Newspaper.{Intake, Publishing}
  alias Newspaper.Publishing.GeneratedFeed
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> assign(:creating, false)
     |> assign(:editing_feed_id, nil)
     |> assign(:edit_intake_group_ids, [])
     |> assign(:edit_input_feed_ids, [])
     |> assign_form()
     |> assign_data()}
  end

  def handle_event("show_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
     |> assign(:editing_feed_id, nil)
     |> assign(:edit_intake_group_ids, [])
     |> assign(:edit_input_feed_ids, [])
     |> assign_form()}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, socket |> assign(:creating, false) |> assign_form()}
  end

  def handle_event("save_feed", %{"generated_feed" => params}, socket) do
    case Publishing.create_generated_feed(params) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Output feed created")
         |> assign(:creating, false)
         |> assign_form()
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, socket |> assign(:creating, true) |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Publishing.get_generated_feed!(to_id(id))

    {:noreply,
     socket
     |> assign(:creating, false)
     |> assign(:editing_feed_id, feed.id)
     |> assign(:edit_form, to_form(Publishing.change_generated_feed(feed)))
     |> assign(:edit_intake_group_ids, Enum.map(feed.intake_groups, & &1.id))
     |> assign(:edit_input_feed_ids, Enum.map(feed.input_feeds, & &1.id))}
  end

  def handle_event("cancel_edit_feed", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_feed_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:edit_intake_group_ids, [])
     |> assign(:edit_input_feed_ids, [])}
  end

  def handle_event("update_feed", %{"generated_feed" => params}, socket) do
    feed = Publishing.get_generated_feed!(socket.assigns.editing_feed_id)

    case Publishing.update_generated_feed(feed, params) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Output feed updated")
         |> assign(:editing_feed_id, nil)
         |> assign(:edit_form, nil)
         |> assign(:edit_intake_group_ids, [])
         |> assign(:edit_input_feed_ids, [])
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    feed = Publishing.get_generated_feed!(to_id(id))

    case Publishing.delete_generated_feed(feed) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Output feed deleted")
         |> assign(:editing_feed_id, nil)
         |> assign(:edit_form, nil)
         |> assign(:edit_intake_group_ids, [])
         |> assign(:edit_input_feed_ids, [])
         |> assign_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Output feed could not be deleted")
         |> assign_data()}
    end
  end

  def handle_event("toggle_feed", %{"id" => id}, socket) do
    feed = Publishing.get_generated_feed!(to_id(id))
    {:ok, _feed} = Publishing.update_generated_feed(feed, %{enabled: !feed.enabled})

    {:noreply, assign_data(socket)}
  end

  def handle_event("publish_feed", %{"id" => id}, socket) do
    handle_event("backfill_feed", %{"id" => id}, socket)
  end

  def handle_event("backfill_feed", %{"id" => id}, socket) do
    id = to_id(id)

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Newspaper.Pipeline.backfill_output_feed(id, "manual")
    end)

    {:noreply, socket |> put_flash(:info, "Output feed backfill started") |> assign_data()}
  end

  def handle_event("rerender_feed", %{"id" => id}, socket) do
    id = to_id(id)

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      Newspaper.Pipeline.rerender_output_feed(id, "manual")
    end)

    {:noreply, socket |> put_flash(:info, "Output feed re-render started") |> assign_data()}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="output-feeds" />
      <header class="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Publishing
          </p>
          <h1 class="text-2xl font-semibold">Output feeds</h1>
          <p class="mt-1 text-sm text-base-content/65">
            Compose durable feeds from intake groups and individual sources.
          </p>
        </div>
        <button id="add-output-feed" class="btn btn-primary self-start" phx-click="show_create">
          <.icon name="hero-plus" class="size-4" /> Add output feed
        </button>
      </header>

      <section
        :if={@creating}
        id="output-feed-create-panel"
        class="mb-10 border-y border-base-300 py-6"
      >
        <div class="mb-5 flex items-center justify-between gap-4">
          <h2 class="text-base font-semibold">New output feed</h2>
          <button
            id="cancel-output-feed-create"
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="cancel_create"
            title="Close"
            aria-label="Close creation form"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>
        <.output_feed_form
          form={@form}
          id="new-output-feed-form"
          submit="save_feed"
          groups={@groups}
          input_feeds={@input_feeds}
          intake_group_ids={[]}
          input_feed_ids={[]}
          submit_label="Create output feed"
        />
      </section>

      <section id="generated-feeds" class="divide-y divide-base-300 border-y border-base-300">
        <div :if={@feed_count == 0} class="py-12 text-center">
          <p class="font-medium">No output feeds configured.</p>
          <p class="mt-1 text-sm text-base-content/55">Add one to start composing a feed.</p>
        </div>

        <article :for={feed <- @feeds} id={"output-feed-#{feed.id}"} class="py-5">
          <div class="grid gap-4 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start">
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="font-semibold">{feed.title}</h2>
                <span class={
                  if(feed.enabled, do: "badge badge-success badge-soft", else: "badge badge-ghost")
                }>
                  {if feed.enabled, do: "Enabled", else: "Disabled"}
                </span>
                <span class="badge badge-ghost">{feed.item_limit} items</span>
              </div>
              <p :if={feed.description not in [nil, ""]} class="mt-1 text-sm text-base-content/65">
                {feed.description}
              </p>
              <div class="mt-3 flex flex-wrap gap-x-4 gap-y-1 text-xs text-base-content/55">
                <span>{feed_membership_label(feed)}</span>
                <span>{pipeline_label(feed)}</span>
                <span>{body_label(feed)}</span>
              </div>
              <a
                href={"/feeds/#{feed.guid}.xml"}
                target="_blank"
                class="mt-2 inline-flex max-w-full items-center gap-1 truncate text-xs text-primary hover:underline"
              >
                /feeds/{feed.guid}.xml
                <.icon name="hero-arrow-top-right-on-square" class="size-3.5 shrink-0" />
              </a>
            </div>

            <div class="flex items-center gap-2 lg:justify-end">
              <.link
                navigate={~p"/output-feeds/#{feed.id}/pipeline"}
                class="btn btn-sm"
                id={"pipeline-output-feed-#{feed.id}"}
              >
                <.icon name="hero-queue-list" class="size-4" /> Pipeline
              </.link>
              <.output_feed_actions feed={feed} />
            </div>
          </div>

          <div :if={@editing_feed_id == feed.id} class="mt-5 border-t border-base-300 pt-5">
            <h3 class="mb-4 text-sm font-semibold">Edit {feed.title}</h3>
            <.output_feed_form
              form={@edit_form}
              id={"edit-output-feed-form-#{feed.id}"}
              submit="update_feed"
              groups={@groups}
              input_feeds={@input_feeds}
              intake_group_ids={@edit_intake_group_ids}
              input_feed_ids={@edit_input_feed_ids}
              submit_label="Save output feed"
              editing_id={feed.id}
            />
            <button type="button" class="btn mt-3" phx-click="cancel_edit_feed">Cancel</button>
          </div>
        </article>
      </section>
    </Layouts.app>
    """
  end

  attr :form, :any, required: true
  attr :id, :string, required: true
  attr :submit, :string, required: true
  attr :groups, :list, required: true
  attr :input_feeds, :list, required: true
  attr :intake_group_ids, :list, required: true
  attr :input_feed_ids, :list, required: true
  attr :submit_label, :string, required: true
  attr :editing_id, :integer, default: nil

  defp output_feed_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} class="grid gap-4 md:grid-cols-2">
      <.input
        id={edit_field_id("title", @editing_id)}
        field={@form[:title]}
        label="Title"
      />
      <.input
        id={edit_field_id("item-limit", @editing_id)}
        field={@form[:item_limit]}
        label="Item limit"
        type="number"
      />
      <.input
        id={edit_field_id("description", @editing_id)}
        field={@form[:description]}
        label="Description"
        type="textarea"
      />
      <div class="grid content-start gap-2 pt-7">
        <.input
          :if={@editing_id}
          id={edit_field_id("enabled", @editing_id)}
          field={@form[:enabled]}
          label="Enabled"
          type="checkbox"
        />
        <.input
          id={edit_field_id("process-items", @editing_id)}
          field={@form[:process_items]}
          label="Process/extract items"
          type="checkbox"
        />
        <.input
          id={edit_field_id("link-to-hosted-article", @editing_id)}
          field={@form[:link_to_hosted_article]}
          label="Link to hosted article"
          type="checkbox"
        />
        <.input
          id={edit_field_id("use-extracted-content-body", @editing_id)}
          field={@form[:use_extracted_content_body]}
          label="Use extracted content body"
          type="checkbox"
        />
      </div>
      <.input
        name="generated_feed[intake_group_ids][]"
        label="Included intake groups"
        type="select"
        multiple
        options={Enum.map(@groups, &{&1.name, &1.id})}
        value={@intake_group_ids}
        class="select select-bordered min-h-32 w-full"
      />
      <.input
        name="generated_feed[input_feed_ids][]"
        label="Included input feeds"
        type="select"
        multiple
        options={Enum.map(@input_feeds, &{&1.name, &1.id})}
        value={@input_feed_ids}
        class="select select-bordered min-h-32 w-full"
      />
      <div class="md:col-span-2">
        <.button><.icon name="hero-check" class="size-4" /> {@submit_label}</.button>
      </div>
    </.form>
    """
  end

  attr :feed, GeneratedFeed, required: true

  defp output_feed_actions(assigns) do
    ~H"""
    <details
      id={"output-feed-actions-#{@feed.id}"}
      class="dropdown dropdown-end"
      phx-click-away={JS.remove_attribute("open")}
    >
      <summary
        class="btn btn-ghost btn-sm btn-square"
        title="Output feed actions"
        aria-label="Output feed actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </summary>
      <ul class="menu dropdown-content z-20 mt-1 w-48 border border-base-300 bg-base-100 p-1 shadow-lg">
        <li>
          <button phx-click="edit_feed" phx-value-id={@feed.id} id={"edit-output-feed-#{@feed.id}"}>
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </button>
        </li>
        <li>
          <button
            phx-click="backfill_feed"
            phx-value-id={@feed.id}
            id={"backfill-output-feed-#{@feed.id}"}
          >
            <.icon name="hero-plus-circle" class="size-4" /> Backfill
          </button>
        </li>
        <li>
          <button
            phx-click="rerender_feed"
            phx-value-id={@feed.id}
            id={"rerender-output-feed-#{@feed.id}"}
          >
            <.icon name="hero-arrow-path-rounded-square" class="size-4" /> Re-render
          </button>
        </li>
        <li>
          <button
            phx-click="toggle_feed"
            phx-value-id={@feed.id}
            id={"toggle-output-feed-#{@feed.id}"}
          >
            <.icon name={if(@feed.enabled, do: "hero-pause", else: "hero-play")} class="size-4" />
            {if @feed.enabled, do: "Disable", else: "Enable"}
          </button>
        </li>
        <li>
          <button
            class="text-error"
            phx-click="delete_feed"
            phx-value-id={@feed.id}
            data-confirm="Delete this output feed?"
            id={"delete-output-feed-#{@feed.id}"}
          >
            <.icon name="hero-trash" class="size-4" /> Delete
          </button>
        </li>
      </ul>
    </details>
    """
  end

  defp assign_data(socket) do
    feeds = Publishing.list_generated_feeds()

    socket
    |> assign(:feeds, feeds)
    |> assign(:feed_count, length(feeds))
    |> assign(:groups, Intake.list_intake_groups())
    |> assign(:input_feeds, Intake.list_input_feeds())
  end

  defp assign_form(socket) do
    socket
    |> assign(:form, to_form(Publishing.change_generated_feed(%GeneratedFeed{item_limit: 500})))
    |> assign(:edit_form, nil)
  end

  defp edit_field_id(_field, nil), do: nil
  defp edit_field_id(field, id), do: "edit-output-feed-#{field}-#{id}"

  defp feed_membership_label(feed) do
    group_count = length(feed.intake_groups)
    source_count = length(feed.input_feeds)
    "#{group_count} groups · #{source_count} individual feeds"
  end

  defp pipeline_label(feed) do
    extraction_steps =
      Enum.count(feed.pipeline_steps, &(&1.step_type == "extraction" and &1.enabled))

    case extraction_steps do
      0 -> "No extraction pipeline"
      1 -> "Extraction enabled"
      count -> "#{count} extraction steps"
    end
  end

  defp body_label(%{process_items: false}), do: "Original content"
  defp body_label(%{use_extracted_content_body: true}), do: "Extracted body"
  defp body_label(%{link_to_hosted_article: true}), do: "Hosted article links"
  defp body_label(_feed), do: "Extraction enabled"

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)
end
