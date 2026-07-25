defmodule NewspaperWeb.AdminLive.OutputFeeds do
  use NewspaperWeb, :live_view

  alias Newspaper.{Intake, Publishing}
  alias Newspaper.Publishing.GeneratedFeed
  alias NewspaperWeb.AdminLive.Format
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> assign(:creating, false)
     |> assign_form()
     |> assign_data()}
  end

  def handle_event("show_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:creating, true)
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

  def handle_event("delete_feed", %{"id" => id}, socket) do
    feed = Publishing.get_generated_feed!(to_id(id))

    case Publishing.delete_generated_feed(feed) do
      {:ok, _feed} ->
        {:noreply,
         socket
         |> put_flash(:info, "Output feed deleted")
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

    case Publishing.update_generated_feed(feed, %{enabled: not feed.enabled}) do
      {:ok, _feed} ->
        {:noreply, assign_data(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Output feed could not be updated")}
    end
  end

  def handle_info({:newspaper_data_changed, event}, socket)
      when event in [:publishing_changed, :processing_changed, :intake_changed] do
    {:noreply, assign_data(socket)}
  end

  def handle_info({:newspaper_data_changed, _event}, socket), do: {:noreply, socket}

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
              <button
                class="btn btn-sm btn-square"
                phx-click="toggle_feed"
                phx-value-id={feed.id}
                id={"toggle-output-feed-#{feed.id}"}
                title={if feed.enabled, do: "Disable output feed", else: "Enable output feed"}
                aria-label={if feed.enabled, do: "Disable output feed", else: "Enable output feed"}
              >
                <.icon name={if feed.enabled, do: "hero-pause", else: "hero-play"} class="size-4" />
              </button>
              <.link
                navigate={~p"/output-feeds/#{feed.id}"}
                class="btn btn-sm"
                id={"open-output-feed-#{feed.id}"}
              >
                <.icon name="hero-adjustments-horizontal" class="size-4" /> Configure
              </.link>
              <button
                class="btn btn-error btn-soft btn-sm btn-square"
                phx-click="delete_feed"
                phx-value-id={feed.id}
                data-confirm="Delete this output feed?"
                id={"delete-output-feed-#{feed.id}"}
                title="Delete output feed"
                aria-label="Delete output feed"
              >
                <.icon name="hero-trash" class="size-4" />
              </button>
            </div>
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

  defp output_feed_form(assigns) do
    ~H"""
    <.form for={@form} id={@id} phx-submit={@submit} class="grid gap-4 md:grid-cols-2">
      <.input field={@form[:title]} label="Title" />
      <.input
        field={@form[:item_limit]}
        label="Item limit"
        type="number"
      />
      <.input
        field={@form[:description]}
        label="Description"
        type="textarea"
      />
      <input
        id={"#{@id}-intake-groups-empty"}
        type="hidden"
        name="generated_feed[intake_group_ids][]"
        value=""
      />
      <.input
        name="generated_feed[intake_group_ids][]"
        label="Included intake groups"
        type="select"
        multiple
        options={Enum.map(@groups, &{&1.name, &1.id})}
        value={@intake_group_ids}
        class="select select-bordered min-h-32 w-full"
      />
      <input
        id={"#{@id}-input-feeds-empty"}
        type="hidden"
        name="generated_feed[input_feed_ids][]"
        value=""
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

  defp assign_data(socket) do
    feeds = Publishing.list_generated_feeds()

    socket
    |> assign(:feeds, feeds)
    |> assign(:feed_count, length(feeds))
    |> assign(:groups, Intake.list_intake_groups())
    |> assign(:input_feeds, Intake.list_input_feeds())
  end

  defp assign_form(socket) do
    assign(
      socket,
      :form,
      to_form(Publishing.change_generated_feed(%GeneratedFeed{item_limit: 500}))
    )
  end

  defp feed_membership_label(feed) do
    group_count = length(feed.intake_groups)
    source_count = length(feed.input_feeds)
    "#{group_count} groups · #{source_count} individual feeds"
  end

  defp pipeline_label(feed) do
    enabled_types =
      feed.pipeline_steps
      |> Enum.filter(& &1.enabled)
      |> Enum.map(& &1.step_type)

    cond do
      enabled_types == [] ->
        "No active processing"

      enabled_types == ["extraction"] ->
        "Extracts future articles"

      enabled_types == ["digestion"] ->
        "Digests future articles"

      "extraction" in enabled_types and "digestion" in enabled_types ->
        "Extracts + digests future articles"

      true ->
        "#{length(enabled_types)} active steps"
    end
  end

  defp body_label(feed) do
    title = if feed.title_source == "digest", do: "digest title", else: "original title"

    body =
      case feed.body_source do
        "extracted_content" -> "extracted body"
        "digest_summary" -> "digest summary"
        _body_source -> "original body"
      end

    link = if feed.link_to_hosted_article, do: "hosted link", else: "original link"
    Enum.join([title, body, link], " · ")
  end

  defp to_id(id), do: Format.parse_id(id)
end
