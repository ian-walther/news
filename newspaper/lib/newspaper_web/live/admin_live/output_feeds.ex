defmodule NewspaperWeb.AdminLive.OutputFeeds do
  use NewspaperWeb, :live_view

  alias Newspaper.{Intake, Publishing}
  alias Newspaper.Publishing.GeneratedFeed
  import NewspaperWeb.AdminLive.Nav

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> assign(:editing_feed_id, nil)
     |> assign(:edit_intake_group_ids, [])
     |> assign(:edit_input_feed_ids, [])
     |> assign_form()
     |> assign_data()}
  end

  def handle_event("save_feed", %{"generated_feed" => params}, socket) do
    case Publishing.create_generated_feed(params) do
      {:ok, _feed} ->
        {:noreply,
         socket |> put_flash(:info, "Output feed created") |> assign_form() |> assign_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("edit_feed", %{"id" => id}, socket) do
    feed = Publishing.get_generated_feed!(to_id(id))

    {:noreply,
     socket
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
    <main class="mx-auto max-w-6xl p-6">
      <.nav />
      <h1 class="mb-6 text-2xl font-semibold">Output Feeds</h1>

      <section class="mb-8">
        <h2 class="mb-3 text-lg font-semibold">New Output Feed</h2>
        <.form for={@form} id="new-output-feed-form" phx-submit="save_feed" class="space-y-4">
          <.input field={@form[:title]} label="Title" />
          <.input field={@form[:description]} label="Description" type="textarea" />
          <.input field={@form[:item_limit]} label="Item limit" type="number" />
          <.input field={@form[:process_items]} label="Process/extract items" type="checkbox" />
          <.input
            field={@form[:link_to_hosted_article]}
            label="Link to hosted article"
            type="checkbox"
          />
          <.input
            field={@form[:use_extracted_content_body]}
            label="Use extracted content body"
            type="checkbox"
          />
          <.input
            name="generated_feed[intake_group_ids][]"
            label="Included intake groups"
            type="select"
            multiple
            options={Enum.map(@groups, &{&1.name, &1.id})}
            value={[]}
            class="select select-bordered min-h-32 w-full"
          />
          <.input
            name="generated_feed[input_feed_ids][]"
            label="Included input feeds"
            type="select"
            multiple
            options={Enum.map(@input_feeds, &{&1.name, &1.id})}
            value={[]}
            class="select select-bordered min-h-32 w-full"
          />
          <.button>Create output feed</.button>
        </.form>
      </section>

      <.table id="generated-feeds" rows={@feeds}>
        <:col :let={feed} label="Title">{feed.title}</:col>
        <:col :let={feed} label="URL">{"/feeds/#{feed.guid}.xml"}</:col>
        <:col :let={feed} label="Item limit">{feed.item_limit}</:col>
        <:col :let={feed} label="Enabled">{if feed.enabled, do: "yes", else: "no"}</:col>
        <:action :let={feed}>
          <.link
            navigate={~p"/output-feeds/#{feed.id}/pipeline"}
            class="btn btn-sm"
            id={"pipeline-output-feed-#{feed.id}"}
          >
            Pipeline
          </.link>
        </:action>
        <:action :let={feed}>
          <button
            class="btn btn-sm"
            phx-click="edit_feed"
            phx-value-id={feed.id}
            id={"edit-output-feed-#{feed.id}"}
          >
            Edit
          </button>
        </:action>
        <:action :let={feed}>
          <button
            class="btn btn-sm"
            phx-click="backfill_feed"
            phx-value-id={feed.id}
            id={"backfill-output-feed-#{feed.id}"}
          >
            Backfill
          </button>
        </:action>
        <:action :let={feed}>
          <button
            class="btn btn-sm"
            phx-click="rerender_feed"
            phx-value-id={feed.id}
            id={"rerender-output-feed-#{feed.id}"}
          >
            Re-render
          </button>
        </:action>
        <:action :let={feed}>
          <button class="btn btn-sm" phx-click="toggle_feed" phx-value-id={feed.id}>
            {if feed.enabled, do: "Disable", else: "Enable"}
          </button>
        </:action>
        <:action :let={feed}>
          <button
            class="btn btn-sm btn-error btn-soft"
            phx-click="delete_feed"
            phx-value-id={feed.id}
            data-confirm="Delete this output feed?"
            id={"delete-output-feed-#{feed.id}"}
          >
            Delete
          </button>
        </:action>
      </.table>

      <section :if={@editing_feed_id} class="mt-8">
        <h2 class="mb-3 text-lg font-semibold">Edit Output Feed</h2>
        <.form
          for={@edit_form}
          id={"edit-output-feed-form-#{@editing_feed_id}"}
          phx-submit="update_feed"
          class="space-y-4"
        >
          <.input
            id={"edit-output-feed-title-#{@editing_feed_id}"}
            field={@edit_form[:title]}
            label="Title"
          />
          <.input
            id={"edit-output-feed-description-#{@editing_feed_id}"}
            field={@edit_form[:description]}
            label="Description"
            type="textarea"
          />
          <.input
            id={"edit-output-feed-item-limit-#{@editing_feed_id}"}
            field={@edit_form[:item_limit]}
            label="Item limit"
            type="number"
          />
          <.input
            id={"edit-output-feed-enabled-#{@editing_feed_id}"}
            field={@edit_form[:enabled]}
            label="Enabled"
            type="checkbox"
          />
          <.input
            id={"edit-output-feed-process-items-#{@editing_feed_id}"}
            field={@edit_form[:process_items]}
            label="Process/extract items"
            type="checkbox"
          />
          <.input
            id={"edit-output-feed-link-to-hosted-article-#{@editing_feed_id}"}
            field={@edit_form[:link_to_hosted_article]}
            label="Link to hosted article"
            type="checkbox"
          />
          <.input
            id={"edit-output-feed-use-extracted-content-body-#{@editing_feed_id}"}
            field={@edit_form[:use_extracted_content_body]}
            label="Use extracted content body"
            type="checkbox"
          />
          <.input
            name="generated_feed[intake_group_ids][]"
            label="Included intake groups"
            type="select"
            multiple
            options={Enum.map(@groups, &{&1.name, &1.id})}
            value={@edit_intake_group_ids}
            class="select select-bordered min-h-32 w-full"
          />
          <.input
            name="generated_feed[input_feed_ids][]"
            label="Included input feeds"
            type="select"
            multiple
            options={Enum.map(@input_feeds, &{&1.name, &1.id})}
            value={@edit_input_feed_ids}
            class="select select-bordered min-h-32 w-full"
          />
          <div class="flex gap-2">
            <.button>Save output feed</.button>
            <button type="button" class="btn" phx-click="cancel_edit_feed">
              Cancel
            </button>
          </div>
        </.form>
      </section>
    </main>
    """
  end

  defp assign_data(socket) do
    socket
    |> assign(:feeds, Publishing.list_generated_feeds())
    |> assign(:groups, Intake.list_intake_groups())
    |> assign(:input_feeds, Intake.list_input_feeds())
  end

  defp assign_form(socket) do
    socket
    |> assign(:form, to_form(Publishing.change_generated_feed(%GeneratedFeed{item_limit: 500})))
    |> assign(:edit_form, nil)
  end

  defp to_id(id) when is_integer(id), do: id
  defp to_id(id) when is_binary(id), do: String.to_integer(id)
end
