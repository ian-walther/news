defmodule NewspaperWeb.AdminLive.Intake do
  use NewspaperWeb, :live_view

  alias Newspaper.{Intake, Pipeline}
  alias Newspaper.Intake.{InputFeed, IntakeGroup}
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> assign(:creating, nil)
     |> assign(:editing_group_id, nil)
     |> assign(:editing_feed_id, nil)
     |> assign_forms()
     |> assign_data()}
  end

  def handle_event("show_create", %{"type" => type}, socket) when type in ["group", "feed"] do
    {:noreply, socket |> assign(:creating, type) |> assign_new_forms()}
  end

  def handle_event("cancel_create", _params, socket) do
    {:noreply, socket |> assign(:creating, nil) |> assign_new_forms()}
  end

  def handle_event("save_group", %{"intake_group" => params}, socket) do
    case Intake.create_intake_group(params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intake group created")
         |> assign(:creating, nil)
         |> assign_new_forms()
         |> assign_data()}

      {:error, changeset} ->
        {:noreply,
         socket |> assign(:creating, "group") |> assign(:group_form, to_form(changeset))}
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    group = Intake.get_intake_group!(to_id(id))

    {:noreply,
     socket
     |> assign(:creating, nil)
     |> assign(:editing_group_id, group.id)
     |> assign(:group_edit_form, to_form(Intake.change_intake_group(group)))}
  end

  def handle_event("cancel_edit_group", _params, socket) do
    {:noreply, socket |> assign(:editing_group_id, nil) |> assign(:group_edit_form, nil)}
  end

  def handle_event("update_group", %{"intake_group" => params}, socket) do
    group = Intake.get_intake_group!(socket.assigns.editing_group_id)

    case Intake.update_intake_group(group, params) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intake group updated")
         |> assign(:editing_group_id, nil)
         |> assign(:group_edit_form, nil)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :group_edit_form, to_form(changeset))}
    end
  end

  def handle_event("delete_group", %{"id" => id}, socket) do
    group = Intake.get_intake_group!(to_id(id))

    case Intake.delete_intake_group(group) do
      {:ok, _group} ->
        {:noreply,
         socket
         |> put_flash(:info, "Intake group deleted")
         |> assign(:editing_group_id, nil)
         |> assign(:group_edit_form, nil)
         |> assign_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Intake group could not be deleted while feeds or history use it")
         |> assign_data()}
    end
  end

  def handle_event("save_feed", %{"input_feed" => params}, socket) do
    params = blank_group_to_nil(params)

    case Intake.create_input_feed(params) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Input feed created")
         |> assign(:creating, nil)
         |> assign_new_forms()
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, socket |> assign(:creating, "feed") |> assign(:feed_form, to_form(changeset))}
    end
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Intake.get_input_feed!(to_id(id))

    {:noreply,
     socket
     |> assign(:creating, nil)
     |> assign(:editing_feed_id, feed.id)
     |> assign(:feed_edit_form, to_form(Intake.change_input_feed(feed)))}
  end

  def handle_event("cancel_edit_feed", _params, socket) do
    {:noreply, socket |> assign(:editing_feed_id, nil) |> assign(:feed_edit_form, nil)}
  end

  def handle_event("update_feed", %{"input_feed" => params}, socket) do
    feed = Intake.get_input_feed!(socket.assigns.editing_feed_id)
    params = blank_group_to_nil(params)

    case Intake.update_input_feed(feed, params) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Input feed updated")
         |> assign(:editing_feed_id, nil)
         |> assign(:feed_edit_form, nil)
         |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :feed_edit_form, to_form(changeset))}
    end
  end

  def handle_event("delete_feed", %{"id" => id}, socket) do
    feed = Intake.get_input_feed!(to_id(id))

    case Intake.delete_input_feed(feed) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Input feed deleted")
         |> assign(:editing_feed_id, nil)
         |> assign(:feed_edit_form, nil)
         |> assign_data()}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(
           :error,
           "Input feed could not be deleted while raw items or articles use it"
         )
         |> assign_data()}
    end
  end

  def handle_event("toggle_group", %{"id" => id}, socket) do
    group = Intake.get_intake_group!(to_id(id))
    {:ok, _group} = Intake.update_intake_group(group, %{enabled: !group.enabled})

    {:noreply, assign_data(socket)}
  end

  def handle_event("toggle_feed", %{"id" => id}, socket) do
    feed = Intake.get_input_feed!(to_id(id))
    {:ok, _feed} = Intake.update_input_feed(feed, %{enabled: !feed.enabled})

    {:noreply, assign_data(socket)}
  end

  def handle_event("fetch_feed", %{"id" => id}, socket) do
    id = to_id(id)

    Task.Supervisor.start_child(Newspaper.Processing.TaskSupervisor, fn ->
      id
      |> Intake.get_input_feed!()
      |> Pipeline.fetch_input_feed("manual")
    end)

    {:noreply, socket |> put_flash(:info, "Feed fetch started") |> assign_data()}
  end

  def handle_info({:newspaper_data_changed, :intake_changed}, socket) do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket), do: {:noreply, socket}

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="intake" />

      <header class="mb-8 flex flex-col gap-4 sm:flex-row sm:items-end sm:justify-between">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Sources
          </p>
          <h1 class="text-2xl font-semibold">Intake</h1>
          <p class="mt-1 text-sm text-base-content/65">
            Feeds discover articles; groups define deduplication boundaries.
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button
            id="add-input-feed"
            type="button"
            class="btn btn-primary"
            phx-click="show_create"
            phx-value-type="feed"
          >
            <.icon name="hero-plus" class="size-4" /> Add feed
          </button>
          <button
            id="add-intake-group"
            type="button"
            class="btn"
            phx-click="show_create"
            phx-value-type="group"
          >
            <.icon name="hero-plus" class="size-4" /> Add group
          </button>
        </div>
      </header>

      <section :if={@creating} id="intake-create-panel" class="mb-10 border-y border-base-300 py-6">
        <div class="mb-5 flex items-center justify-between gap-4">
          <h2 class="text-base font-semibold">
            {if @creating == "group", do: "New intake group", else: "New input feed"}
          </h2>
          <button
            id="cancel-intake-create"
            type="button"
            class="btn btn-ghost btn-sm btn-square"
            phx-click="cancel_create"
            title="Close"
            aria-label="Close creation form"
          >
            <.icon name="hero-x-mark" class="size-5" />
          </button>
        </div>

        <div :if={@creating == "group"}>
          <.form
            for={@group_form}
            id="new-intake-group-form"
            phx-submit="save_group"
            class="grid gap-4 md:grid-cols-2"
          >
            <.input field={@group_form[:name]} label="Name" />
            <.input field={@group_form[:outlet_name]} label="Outlet name" />
            <.input
              field={@group_form[:notes]}
              label="Notes"
              type="textarea"
              class="textarea w-full md:col-span-2"
            />
            <div class="md:col-span-2">
              <.button><.icon name="hero-plus" class="size-4" /> Create group</.button>
            </div>
          </.form>
        </div>

        <div :if={@creating == "feed"}>
          <.form
            for={@feed_form}
            id="new-input-feed-form"
            phx-submit="save_feed"
            class="grid gap-4 md:grid-cols-2"
          >
            <.input field={@feed_form[:name]} label="Name" />
            <.input field={@feed_form[:url]} label="URL" type="url" />
            <.input
              field={@feed_form[:intake_group_id]}
              label="Intake group"
              type="select"
              options={@group_options}
            />
            <div class="self-end">
              <.button><.icon name="hero-plus" class="size-4" /> Create feed</.button>
            </div>
          </.form>
        </div>
      </section>

      <section id="ungrouped-input-feeds" class="mb-10">
        <div class="mb-3 flex items-baseline justify-between gap-4">
          <h2 class="text-base font-semibold">Ungrouped feeds</h2>
          <span class="text-xs text-base-content/50">{@ungrouped_feed_count}</span>
        </div>
        <ul class="divide-y divide-base-300 border-y border-base-300 text-sm">
          <li :if={@ungrouped_feed_count == 0} class="py-6 text-base-content/55">
            Every input feed belongs to a group.
          </li>
          <.feed_row
            :for={feed <- @ungrouped_feeds}
            feed={feed}
            group_options={@group_options}
            editing_feed_id={@editing_feed_id}
            feed_edit_form={@feed_edit_form}
          />
        </ul>
      </section>

      <section id="intake-groups">
        <div class="mb-3 flex items-baseline justify-between gap-4">
          <h2 class="text-base font-semibold">Groups</h2>
          <span class="text-xs text-base-content/50">{@group_count}</span>
        </div>
        <div class="divide-y divide-base-300 border-y border-base-300">
          <p :if={@group_count == 0} class="py-8 text-sm text-base-content/55">
            No intake groups configured.
          </p>
          <article :for={group <- @groups} id={"intake-group-#{group.id}"} class="py-5">
            <div class="flex items-start justify-between gap-4">
              <div class="min-w-0">
                <div class="flex flex-wrap items-center gap-2">
                  <h3 class="font-semibold">{group.name}</h3>
                  <span class={
                    if(group.enabled, do: "badge badge-success badge-soft", else: "badge badge-ghost")
                  }>
                    {if group.enabled, do: "Enabled", else: "Disabled"}
                  </span>
                  <span class="text-xs text-base-content/50">
                    {length(group.input_feeds)} {if length(group.input_feeds) == 1,
                      do: "feed",
                      else: "feeds"}
                  </span>
                </div>
                <p :if={group.notes not in [nil, ""]} class="mt-1 text-sm text-base-content/60">
                  {group.notes}
                </p>
              </div>
              <.group_actions group={group} />
            </div>
            <.form
              :if={@editing_group_id == group.id}
              for={@group_edit_form}
              id={"edit-intake-group-form-#{group.id}"}
              phx-submit="update_group"
              class="mt-5 grid gap-3 border-t border-base-300 pt-5 md:grid-cols-2"
            >
              <.input
                id={"edit-intake-group-name-#{group.id}"}
                field={@group_edit_form[:name]}
                label="Name"
              />
              <.input
                id={"edit-intake-group-outlet-name-#{group.id}"}
                field={@group_edit_form[:outlet_name]}
                label="Outlet name"
              />
              <.input
                id={"edit-intake-group-notes-#{group.id}"}
                field={@group_edit_form[:notes]}
                label="Notes"
                type="textarea"
              />
              <.input
                id={"edit-intake-group-enabled-#{group.id}"}
                field={@group_edit_form[:enabled]}
                label="Enabled"
                type="checkbox"
              />
              <div class="flex gap-2 md:col-span-2">
                <.button>Save group</.button>
                <button type="button" class="btn" phx-click="cancel_edit_group">
                  Cancel
                </button>
              </div>
            </.form>
            <ul
              :if={group.input_feeds != []}
              class="mt-5 divide-y divide-base-300 border-t border-base-300 text-sm"
            >
              <.feed_row
                :for={feed <- group.input_feeds}
                feed={feed}
                group_options={@group_options}
                editing_feed_id={@editing_feed_id}
                feed_edit_form={@feed_edit_form}
              />
            </ul>
          </article>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :feed, InputFeed, required: true
  attr :group_options, :list, required: true
  attr :editing_feed_id, :integer, default: nil
  attr :feed_edit_form, :any, default: nil

  defp feed_row(assigns) do
    ~H"""
    <li id={"input-feed-#{@feed.id}"} class="py-4">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div class="min-w-0">
          <div class="flex flex-wrap items-center gap-2">
            <span class="font-medium">{@feed.name}</span>
            <span class={
              if(@feed.enabled, do: "badge badge-success badge-soft", else: "badge badge-ghost")
            }>
              {if @feed.enabled, do: "Enabled", else: "Disabled"}
            </span>
            <span class={fetch_status_class(@feed.last_fetch_status)}>
              {fetch_status_label(@feed.last_fetch_status)}
            </span>
          </div>
          <div class="mt-1 break-all text-xs text-base-content/55">{@feed.url}</div>
          <div :if={@feed.last_fetched_at} class="mt-1 text-xs text-base-content/45">
            Last fetched <.local_time id={"feed-fetched-#{@feed.id}"} value={@feed.last_fetched_at} />
          </div>
        </div>
        <div class="flex shrink-0 items-center gap-2 sm:justify-end">
          <button
            class="btn btn-sm"
            phx-click="fetch_feed"
            phx-value-id={@feed.id}
            id={"fetch-feed-#{@feed.id}"}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Fetch
          </button>
          <.feed_actions feed={@feed} />
        </div>
      </div>

      <.form
        :if={@editing_feed_id == @feed.id}
        for={@feed_edit_form}
        id={"edit-input-feed-form-#{@feed.id}"}
        phx-submit="update_feed"
        class="mt-5 grid gap-3 border-t border-base-300 pt-5 md:grid-cols-2"
      >
        <.input id={"edit-input-feed-name-#{@feed.id}"} field={@feed_edit_form[:name]} label="Name" />
        <.input id={"edit-input-feed-url-#{@feed.id}"} field={@feed_edit_form[:url]} label="URL" />
        <.input
          id={"edit-input-feed-outlet-name-#{@feed.id}"}
          field={@feed_edit_form[:outlet_name]}
          label="Outlet name"
        />
        <.input
          id={"edit-input-feed-intake-group-#{@feed.id}"}
          field={@feed_edit_form[:intake_group_id]}
          label="Intake group"
          type="select"
          options={@group_options}
        />
        <.input
          id={"edit-input-feed-enabled-#{@feed.id}"}
          field={@feed_edit_form[:enabled]}
          label="Enabled"
          type="checkbox"
        />
        <.input
          id={"edit-input-feed-auth-required-#{@feed.id}"}
          field={@feed_edit_form[:auth_required]}
          label="Signed-in headed browser required (reserved)"
          type="checkbox"
          disabled
        />
        <p class="text-xs text-base-content/55 md:col-span-2">
          Reserved for the headed-browser extraction tier; it does not affect fetching yet.
        </p>
        <div class="flex gap-2 md:col-span-2">
          <.button>Save feed</.button>
          <button type="button" class="btn" phx-click="cancel_edit_feed">
            Cancel
          </button>
        </div>
      </.form>
    </li>
    """
  end

  attr :group, IntakeGroup, required: true

  defp group_actions(assigns) do
    ~H"""
    <details
      id={"group-actions-#{@group.id}"}
      class="dropdown dropdown-end shrink-0"
      phx-click-away={JS.remove_attribute("open")}
    >
      <summary
        class="btn btn-ghost btn-sm btn-square"
        title="Group actions"
        aria-label="Group actions"
      >
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </summary>
      <ul class="menu dropdown-content z-20 mt-1 w-44 border border-base-300 bg-base-100 p-1 shadow-lg">
        <li>
          <button phx-click="edit_group" phx-value-id={@group.id} id={"edit-group-#{@group.id}"}>
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </button>
        </li>
        <li>
          <button phx-click="toggle_group" phx-value-id={@group.id} id={"toggle-group-#{@group.id}"}>
            <.icon name={if(@group.enabled, do: "hero-pause", else: "hero-play")} class="size-4" />
            {if @group.enabled, do: "Disable", else: "Enable"}
          </button>
        </li>
        <li>
          <button
            class="text-error"
            phx-click="delete_group"
            phx-value-id={@group.id}
            data-confirm="Delete this intake group?"
            id={"delete-group-#{@group.id}"}
          >
            <.icon name="hero-trash" class="size-4" /> Delete
          </button>
        </li>
      </ul>
    </details>
    """
  end

  attr :feed, InputFeed, required: true

  defp feed_actions(assigns) do
    ~H"""
    <details
      id={"feed-actions-#{@feed.id}"}
      class="dropdown dropdown-end"
      phx-click-away={JS.remove_attribute("open")}
    >
      <summary class="btn btn-ghost btn-sm btn-square" title="Feed actions" aria-label="Feed actions">
        <.icon name="hero-ellipsis-horizontal" class="size-5" />
      </summary>
      <ul class="menu dropdown-content z-20 mt-1 w-44 border border-base-300 bg-base-100 p-1 shadow-lg">
        <li>
          <button phx-click="edit_feed" phx-value-id={@feed.id} id={"edit-feed-#{@feed.id}"}>
            <.icon name="hero-pencil-square" class="size-4" /> Edit
          </button>
        </li>
        <li>
          <button phx-click="toggle_feed" phx-value-id={@feed.id} id={"toggle-feed-#{@feed.id}"}>
            <.icon name={if(@feed.enabled, do: "hero-pause", else: "hero-play")} class="size-4" />
            {if @feed.enabled, do: "Disable", else: "Enable"}
          </button>
        </li>
        <li>
          <button
            class="text-error"
            phx-click="delete_feed"
            phx-value-id={@feed.id}
            data-confirm="Delete this input feed?"
            id={"delete-feed-#{@feed.id}"}
          >
            <.icon name="hero-trash" class="size-4" /> Delete
          </button>
        </li>
      </ul>
    </details>
    """
  end

  defp assign_data(socket) do
    groups = Intake.list_intake_groups()

    socket
    |> assign(:groups, groups)
    |> assign(:group_count, length(groups))
    |> then(fn socket ->
      ungrouped_feeds = Intake.list_ungrouped_input_feeds()

      socket
      |> assign(:ungrouped_feeds, ungrouped_feeds)
      |> assign(:ungrouped_feed_count, length(ungrouped_feeds))
    end)
    |> assign(:group_options, [{"No intake group", ""} | Enum.map(groups, &{&1.name, &1.id})])
  end

  defp assign_forms(socket) do
    socket
    |> assign_new_forms()
    |> assign(:group_edit_form, nil)
    |> assign(:feed_edit_form, nil)
  end

  defp assign_new_forms(socket) do
    socket
    |> assign(:group_form, to_form(Intake.change_intake_group(%IntakeGroup{})))
    |> assign(:feed_form, to_form(Intake.change_input_feed(%InputFeed{})))
  end

  defp blank_group_to_nil(%{"intake_group_id" => ""} = params),
    do: %{params | "intake_group_id" => nil}

  defp blank_group_to_nil(params), do: params

  defp fetch_status_label("ok"), do: "Healthy"
  defp fetch_status_label("failed"), do: "Failed"
  defp fetch_status_label(_status), do: "Never fetched"

  defp fetch_status_class("ok"), do: "badge badge-success badge-soft"
  defp fetch_status_class("failed"), do: "badge badge-error badge-soft"
  defp fetch_status_class(_status), do: "badge badge-ghost"

  defp to_id(id), do: Format.parse_id(id)
end
