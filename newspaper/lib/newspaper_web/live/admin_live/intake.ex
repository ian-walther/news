defmodule NewspaperWeb.AdminLive.Intake do
  use NewspaperWeb, :live_view

  alias Newspaper.{Intake, Pipeline}
  alias Newspaper.Intake.{InputFeed, IntakeGroup}
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> assign(:editing_group_id, nil)
     |> assign(:editing_feed_id, nil)
     |> assign_forms()
     |> assign_data()}
  end

  def handle_event("save_group", %{"intake_group" => params}, socket) do
    case Intake.create_intake_group(params) do
      {:ok, _group} ->
        {:noreply,
         socket |> put_flash(:info, "Intake group created") |> assign_forms() |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :group_form, to_form(changeset))}
    end
  end

  def handle_event("edit_group", %{"id" => id}, socket) do
    group = Intake.get_intake_group!(to_id(id))

    {:noreply,
     socket
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
         socket |> put_flash(:info, "Input feed created") |> assign_forms() |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :feed_form, to_form(changeset))}
    end
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Intake.get_input_feed!(to_id(id))

    {:noreply,
     socket
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

    Task.start(fn ->
      id
      |> Intake.get_input_feed!()
      |> Pipeline.fetch_input_feed("manual")
    end)

    {:noreply, socket |> put_flash(:info, "Feed fetch started") |> assign_data()}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_data(socket)}
  end

  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Intake</h1>

      <div class="grid gap-8 lg:grid-cols-2">
        <section>
          <h2 class="mb-3 text-lg font-semibold">New Intake Group</h2>
          <.form
            for={@group_form}
            id="new-intake-group-form"
            phx-submit="save_group"
            class="space-y-4"
          >
            <.input field={@group_form[:name]} label="Name" />
            <.input field={@group_form[:outlet_name]} label="Outlet name" />
            <.input field={@group_form[:notes]} label="Notes" type="textarea" />
            <.button>Create group</.button>
          </.form>
        </section>

        <section>
          <h2 class="mb-3 text-lg font-semibold">New Input Feed</h2>
          <.form for={@feed_form} id="new-input-feed-form" phx-submit="save_feed" class="space-y-4">
            <.input field={@feed_form[:name]} label="Name" />
            <.input field={@feed_form[:url]} label="URL" />
            <.input
              field={@feed_form[:intake_group_id]}
              label="Intake group"
              type="select"
              options={@group_options}
            />
            <.button>Create feed</.button>
          </.form>
        </section>
      </div>

      <section class="mt-8">
        <h2 class="mb-3 text-lg font-semibold">Ungrouped Feeds</h2>
        <ul class="space-y-2 text-sm">
          <.feed_row
            :for={feed <- @ungrouped_feeds}
            feed={feed}
            group_options={@group_options}
            editing_feed_id={@editing_feed_id}
            feed_edit_form={@feed_edit_form}
          />
        </ul>
      </section>

      <section class="mt-8">
        <h2 class="mb-3 text-lg font-semibold">Groups</h2>
        <div class="space-y-4">
          <div :for={group <- @groups} class="rounded border p-4">
            <div class="flex items-start justify-between gap-4">
              <div>
                <div class="font-semibold">{group.name}</div>
                <div class="text-sm text-base-content/70">
                  {if group.enabled, do: "enabled", else: "disabled"}
                  <div :if={group.notes not in [nil, ""]}>{group.notes}</div>
                </div>
              </div>
              <div class="flex shrink-0 gap-2">
                <button
                  class="btn btn-sm"
                  phx-click="edit_group"
                  phx-value-id={group.id}
                  id={"edit-group-#{group.id}"}
                >
                  Edit
                </button>
                <button
                  class="btn btn-sm"
                  phx-click="toggle_group"
                  phx-value-id={group.id}
                  id={"toggle-group-#{group.id}"}
                >
                  {if group.enabled, do: "Disable", else: "Enable"}
                </button>
                <button
                  class="btn btn-sm btn-error btn-soft"
                  phx-click="delete_group"
                  phx-value-id={group.id}
                  data-confirm="Delete this intake group?"
                  id={"delete-group-#{group.id}"}
                >
                  Delete
                </button>
              </div>
            </div>
            <.form
              :if={@editing_group_id == group.id}
              for={@group_edit_form}
              id={"edit-intake-group-form-#{group.id}"}
              phx-submit="update_group"
              class="mt-4 grid gap-3 md:grid-cols-2"
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
            <ul class="mt-3 space-y-2 text-sm">
              <.feed_row
                :for={feed <- group.input_feeds}
                feed={feed}
                group_options={@group_options}
                editing_feed_id={@editing_feed_id}
                feed_edit_form={@feed_edit_form}
              />
            </ul>
          </div>
        </div>
      </section>
    </main>
    """
  end

  attr :feed, InputFeed, required: true
  attr :group_options, :list, required: true
  attr :editing_feed_id, :integer, default: nil
  attr :feed_edit_form, :any, default: nil

  defp feed_row(assigns) do
    ~H"""
    <li class="rounded border border-base-300 p-3">
      <div class="flex items-start justify-between gap-4">
        <div>
          <div class="font-medium">{@feed.name}</div>
          <div class="break-all text-base-content/70">{@feed.url}</div>
          <div class="text-base-content/60">
            {if @feed.enabled, do: "enabled", else: "disabled"} - {@feed.last_fetch_status ||
              "never fetched"}
          </div>
        </div>
        <div class="flex shrink-0 gap-2">
          <button
            class="btn btn-sm"
            phx-click="fetch_feed"
            phx-value-id={@feed.id}
            id={"fetch-feed-#{@feed.id}"}
          >
            Fetch
          </button>
          <button
            class="btn btn-sm"
            phx-click="edit_feed"
            phx-value-id={@feed.id}
            id={"edit-feed-#{@feed.id}"}
          >
            Edit
          </button>
          <button
            class="btn btn-sm"
            phx-click="toggle_feed"
            phx-value-id={@feed.id}
            id={"toggle-feed-#{@feed.id}"}
          >
            {if @feed.enabled, do: "Disable", else: "Enable"}
          </button>
          <button
            class="btn btn-sm btn-error btn-soft"
            phx-click="delete_feed"
            phx-value-id={@feed.id}
            data-confirm="Delete this input feed?"
            id={"delete-feed-#{@feed.id}"}
          >
            Delete
          </button>
        </div>
      </div>

      <.form
        :if={@editing_feed_id == @feed.id}
        for={@feed_edit_form}
        id={"edit-input-feed-form-#{@feed.id}"}
        phx-submit="update_feed"
        class="mt-4 grid gap-3 md:grid-cols-2"
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
          label="Auth required"
          type="checkbox"
        />
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

  defp assign_data(socket) do
    groups = Intake.list_intake_groups()

    socket
    |> assign(:groups, groups)
    |> assign(:ungrouped_feeds, Intake.list_ungrouped_input_feeds())
    |> assign(:group_options, [{"No intake group", ""} | Enum.map(groups, &{&1.name, &1.id})])
  end

  defp assign_forms(socket) do
    socket
    |> assign(:group_form, to_form(Intake.change_intake_group(%IntakeGroup{})))
    |> assign(:feed_form, to_form(Intake.change_input_feed(%InputFeed{})))
    |> assign(:group_edit_form, nil)
    |> assign(:feed_edit_form, nil)
  end

  defp blank_group_to_nil(%{"intake_group_id" => ""} = params),
    do: %{params | "intake_group_id" => nil}

  defp blank_group_to_nil(params), do: params

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)
end
