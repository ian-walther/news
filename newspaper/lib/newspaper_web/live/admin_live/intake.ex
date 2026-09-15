defmodule NewspaperWeb.AdminLive.Intake do
  use NewspaperWeb, :live_view

  alias Newspaper.{Content, Intake, Operations, Pipeline}
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Intake.{InputFeed, IntakeGroup}
  alias Newspaper.Processing.Registry
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> stream_configure(:policies, dom_id: &"site-policy-#{&1.id}")
     |> assign(:creating, nil)
     |> assign(:editing_group_id, nil)
     |> assign(:editing_feed_id, nil)
     |> assign(:editing_policy_id, nil)
     |> assign(:policy_edit_form, nil)
     |> assign(:extractors, Registry.extractors())
     |> assign_policy_form()
     |> assign_forms()
     |> assign_data()
     |> assign_policies()}
  end

  def handle_event("fetch_all", _params, socket) do
    Pipeline.Scheduler.fetch_now()
    {:noreply, socket |> put_flash(:info, "Feed refresh started") |> assign_data()}
  end

  def handle_event("create_policy", %{"site_extraction_policy" => params}, socket) do
    case Content.create_site_extraction_policy(params) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Website policy created")
         |> assign_policy_form()
         |> assign_policies()}

      {:error, changeset} ->
        {:noreply, assign(socket, :policy_form, to_form(changeset))}
    end
  end

  def handle_event("edit_policy", %{"id" => id}, socket) do
    policy = Content.get_site_extraction_policy!(to_id(id))

    {:noreply,
     socket
     |> assign(:editing_policy_id, policy.id)
     |> assign(:policy_edit_form, to_form(Content.change_site_extraction_policy(policy)))
     |> assign_policies()}
  end

  def handle_event("cancel_edit_policy", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_policy_id, nil)
     |> assign(:policy_edit_form, nil)
     |> assign_policies()}
  end

  def handle_event("update_policy", %{"site_extraction_policy" => params}, socket) do
    policy = Content.get_site_extraction_policy!(socket.assigns.editing_policy_id)

    case Content.update_site_extraction_policy(policy, params) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Website policy updated")
         |> assign(:editing_policy_id, nil)
         |> assign(:policy_edit_form, nil)
         |> assign_policies()}

      {:error, changeset} ->
        {:noreply, assign(socket, :policy_edit_form, to_form(changeset))}
    end
  end

  def handle_event("delete_policy", %{"id" => id}, socket) do
    policy = Content.get_site_extraction_policy!(to_id(id))
    {:ok, _policy} = Content.delete_site_extraction_policy(policy)

    {:noreply,
     socket
     |> put_flash(:info, "Website policy removed")
     |> assign(:editing_policy_id, nil)
     |> assign(:policy_edit_form, nil)
     |> assign_policies()}
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

  def handle_info({:newspaper_data_changed, :site_extraction_policies_changed}, socket) do
    {:noreply, assign_policies(socket)}
  end

  def handle_info({:newspaper_data_changed, :operations_changed}, socket) do
    {:noreply, assign(socket, :latest_fetch, Operations.latest_run("fetch_all"))}
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
          <h1 class="text-2xl font-semibold">Sources</h1>
          <p class="mt-1 text-sm text-base-content/65">
            Feeds discover articles; groups define deduplication boundaries; website policies
            configure how articles are fetched from each host.
          </p>
          <p :if={@latest_fetch} id="latest-feed-refresh" class="mt-2 text-sm text-base-content/65">
            Last refresh
            <span class={Format.status_badge_class(@latest_fetch.status)}>
              {Format.status_label(@latest_fetch.status)}
            </span>
            <.local_time
              id={"latest-fetch-time-#{@latest_fetch.id}"}
              value={@latest_fetch.started_at}
              class="text-xs text-base-content/55"
            />
            <span class="text-base-content/55">· {Format.run_summary(@latest_fetch)}</span>
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <button id="fetch-all-now" type="button" class="btn" phx-click="fetch_all">
            <.icon name="hero-arrow-path" class="size-4" /> Fetch all now
          </button>
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

      <section id="website-policies" class="mb-10">
        <div class="mb-3 flex items-baseline justify-between gap-4">
          <div>
            <h2 class="text-base font-semibold">Website policies</h2>
            <p class="mt-1 text-sm text-base-content/55">
              Extractor selection, escalation, and request pacing by host. Live pacing and
              backoff state is on the Processing queue.
            </p>
          </div>
          <span class="text-xs text-base-content/50">{@policy_count}</span>
        </div>

        <details id="add-site-policy" class="mb-4 border-y border-base-300 py-4">
          <summary class="btn btn-sm w-fit cursor-pointer list-none">
            <.icon name="hero-plus" class="size-4" /> Add website
          </summary>
          <.form
            for={@policy_form}
            id="new-site-policy-form"
            phx-submit="create_policy"
            class="mt-5 grid gap-4 md:grid-cols-2"
          >
            <.input
              field={@policy_form[:site_host]}
              type="text"
              label="Website host"
              placeholder="example.com"
            />
            <.input
              field={@policy_form[:minimum_implementation]}
              type="select"
              label="Starting extractor"
              options={extractor_options(@extractors)}
            />
            <.input
              field={@policy_form[:minimum_request_interval_ms]}
              type="number"
              label="Minimum request interval (ms)"
            />
            <.input field={@policy_form[:timeout_ms]} type="number" label="Extraction timeout (ms)" />
            <.input
              field={@policy_form[:minimum_text_length]}
              type="number"
              label="Minimum text length"
            />
            <.input
              field={@policy_form[:escalation_enabled]}
              type="checkbox"
              label="Allow escalation"
            />
            <div class="md:col-span-2">
              <.input field={@policy_form[:notes]} type="textarea" label="Notes" />
            </div>
            <div class="md:col-span-2">
              <.button><.icon name="hero-plus" class="size-4" /> Add website</.button>
            </div>
          </.form>
        </details>

        <div
          id="site-policies"
          phx-update="stream"
          class="divide-y divide-base-300 border-y border-base-300"
        >
          <p
            id="site-policies-empty"
            class="hidden only:block py-8 text-center text-sm text-base-content/55"
          >
            No website policies configured. Defaults apply to every host.
          </p>
          <div
            :for={{id, policy} <- @streams.policies}
            id={id}
            class="grid gap-4 py-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h3 class="font-semibold">{policy.site_host}</h3>
                <span class="badge badge-outline">
                  {extractor_label(policy.minimum_implementation)}
                </span>
                <span class={
                  if(policy.escalation_enabled, do: "badge badge-success badge-soft", else: "badge")
                }>
                  {if policy.escalation_enabled, do: "Escalation on", else: "Escalation off"}
                </span>
              </div>
              <div class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-sm text-base-content/65">
                <span>{policy.minimum_request_interval_ms} ms interval</span>
                <span>{policy.timeout_ms} ms timeout</span>
                <span>{policy.minimum_text_length} character minimum</span>
                <span :if={policy.last_successful_implementation}>
                  Last success: {extractor_label(policy.last_successful_implementation)}
                </span>
              </div>
              <p :if={Format.present?(policy.notes)} class="mt-2 text-sm text-base-content/75">
                {policy.notes}
              </p>
            </div>

            <div class="flex flex-wrap gap-2 lg:justify-end">
              <button
                id={"edit-site-policy-#{policy.id}"}
                type="button"
                class="btn btn-sm"
                phx-click="edit_policy"
                phx-value-id={policy.id}
              >
                Edit
              </button>
              <button
                id={"delete-site-policy-#{policy.id}"}
                type="button"
                class="btn btn-error btn-soft btn-sm"
                phx-click="delete_policy"
                phx-value-id={policy.id}
                data-confirm="Remove this website policy? Defaults will be recreated on the next extraction."
              >
                Delete
              </button>
            </div>

            <.form
              :if={@editing_policy_id == policy.id}
              for={@policy_edit_form}
              id={"edit-site-policy-form-#{policy.id}"}
              phx-submit="update_policy"
              class="grid gap-4 border-t border-base-300 pt-5 lg:col-span-2 lg:grid-cols-2"
            >
              <.input
                id={"edit-site-policy-host-#{policy.id}"}
                field={@policy_edit_form[:site_host]}
                type="text"
                label="Website host"
              />
              <.input
                id={"edit-site-policy-extractor-#{policy.id}"}
                field={@policy_edit_form[:minimum_implementation]}
                type="select"
                label="Starting extractor"
                options={extractor_options(@extractors)}
              />
              <.input
                id={"edit-site-policy-interval-#{policy.id}"}
                field={@policy_edit_form[:minimum_request_interval_ms]}
                type="number"
                label="Minimum request interval (ms)"
              />
              <.input
                id={"edit-site-policy-timeout-#{policy.id}"}
                field={@policy_edit_form[:timeout_ms]}
                type="number"
                label="Extraction timeout (ms)"
              />
              <.input
                id={"edit-site-policy-minimum-text-#{policy.id}"}
                field={@policy_edit_form[:minimum_text_length]}
                type="number"
                label="Minimum text length"
              />
              <.input
                id={"edit-site-policy-escalation-#{policy.id}"}
                field={@policy_edit_form[:escalation_enabled]}
                type="checkbox"
                label="Allow escalation"
              />
              <div class="lg:col-span-2">
                <.input
                  id={"edit-site-policy-notes-#{policy.id}"}
                  field={@policy_edit_form[:notes]}
                  type="textarea"
                  label="Notes"
                />
              </div>
              <div class="flex gap-2 lg:col-span-2">
                <.button><.icon name="hero-check" class="size-4" /> Save</.button>
                <button type="button" class="btn" phx-click="cancel_edit_policy">Cancel</button>
              </div>
            </.form>
          </div>
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
    |> assign(:latest_fetch, Operations.latest_run("fetch_all"))
  end

  defp assign_policy_form(socket) do
    form = %SiteExtractionPolicy{} |> Content.change_site_extraction_policy() |> to_form()
    assign(socket, :policy_form, form)
  end

  defp assign_policies(socket) do
    policies = Content.list_site_extraction_policies()

    socket
    |> assign(:policy_count, length(policies))
    |> stream(:policies, policies, reset: true)
  end

  defp extractor_options(extractors), do: Enum.map(extractors, &{&1.label, &1.key})

  defp extractor_label(key) do
    case Registry.fetch_extractor(key) do
      {:ok, extractor} -> extractor.label
      :error -> key
    end
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

  defp fetch_status_label(status) when status in ["ok", "not_modified"], do: "Healthy"
  defp fetch_status_label("failed"), do: "Failed"
  defp fetch_status_label(_status), do: "Never fetched"

  defp fetch_status_class(status) when status in ["ok", "not_modified"],
    do: "badge badge-success badge-soft"

  defp fetch_status_class("failed"), do: "badge badge-error badge-soft"
  defp fetch_status_class(_status), do: "badge badge-ghost"

  defp to_id(id), do: Format.parse_id(id)
end
