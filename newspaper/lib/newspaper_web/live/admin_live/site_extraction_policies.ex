defmodule NewspaperWeb.AdminLive.SiteExtractionPolicies do
  use NewspaperWeb, :live_view

  import NewspaperWeb.AdminLive.Nav

  alias Newspaper.Content
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Processing.Dispatcher
  alias Newspaper.Processing.Registry

  def mount(_params, _session, socket) do
    if connected?(socket), do: Newspaper.Events.subscribe()

    {:ok,
     socket
     |> stream_configure(:policies, dom_id: &"site-policy-#{&1.id}")
     |> assign(:editing_policy_id, nil)
     |> assign(:edit_form, nil)
     |> assign(:extractors, Registry.extractors())
     |> assign_new_form()
     |> assign_policies()}
  end

  def handle_event("create_policy", %{"site_extraction_policy" => params}, socket) do
    case Content.create_site_extraction_policy(params) do
      {:ok, _policy} ->
        {:noreply,
         socket
         |> put_flash(:info, "Website policy created")
         |> assign_new_form()
         |> assign_policies()}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  def handle_event("edit_policy", %{"id" => id}, socket) do
    policy = Content.get_site_extraction_policy!(String.to_integer(id))

    {:noreply,
     socket
     |> assign(:editing_policy_id, policy.id)
     |> assign(:edit_form, to_form(Content.change_site_extraction_policy(policy)))
     |> assign_policies()}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_policy_id, nil)
     |> assign(:edit_form, nil)
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
         |> assign(:edit_form, nil)
         |> assign_policies()}

      {:error, changeset} ->
        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("delete_policy", %{"id" => id}, socket) do
    policy = Content.get_site_extraction_policy!(String.to_integer(id))
    {:ok, _policy} = Content.delete_site_extraction_policy(policy)

    {:noreply,
     socket
     |> put_flash(:info, "Website policy removed")
     |> assign(:editing_policy_id, nil)
     |> assign(:edit_form, nil)
     |> assign_policies()}
  end

  def handle_event("retry_site_now", %{"id" => id}, socket) do
    policy = Content.get_site_extraction_policy!(String.to_integer(id))
    {kind, message} = retry_site_message(policy.site_host)

    {:noreply, socket |> put_flash(kind, message) |> assign_policies()}
  end

  def handle_info({:newspaper_data_changed, _event}, socket) do
    {:noreply, assign_policies(socket)}
  end

  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.nav current="sites" />

      <header class="mb-8 flex flex-wrap items-end justify-between gap-4">
        <div>
          <p class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">
            Extraction
          </p>
          <h1 class="text-2xl font-semibold">Website Policies</h1>
          <p class="mt-1 text-sm text-base-content/65">
            Extractor selection, escalation, and request pacing by host.
          </p>
        </div>
        <div class="text-right">
          <div class="text-2xl font-semibold tabular-nums">{@policy_count}</div>
          <div class="text-sm text-base-content/60">Configured websites</div>
        </div>
      </header>

      <details id="add-site-policy" class="mb-8 border-y border-base-300 py-4">
        <summary class="btn btn-primary w-fit cursor-pointer list-none">
          <.icon name="hero-plus" class="size-4" /> Add website
        </summary>
        <.form
          for={@form}
          id="new-site-policy-form"
          phx-submit="create_policy"
          class="mt-5 grid gap-4 md:grid-cols-2"
        >
          <.input
            field={@form[:site_host]}
            type="text"
            label="Website host"
            placeholder="example.com"
          />
          <.input
            field={@form[:minimum_implementation]}
            type="select"
            label="Starting extractor"
            options={extractor_options(@extractors)}
          />
          <.input
            field={@form[:minimum_request_interval_ms]}
            type="number"
            label="Minimum request interval (ms)"
          />
          <.input field={@form[:timeout_ms]} type="number" label="Extraction timeout (ms)" />
          <.input
            field={@form[:minimum_text_length]}
            type="number"
            label="Minimum text length"
          />
          <.input field={@form[:escalation_enabled]} type="checkbox" label="Allow escalation" />
          <div class="md:col-span-2">
            <.input field={@form[:notes]} type="textarea" label="Notes" />
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
        <p id="site-policies-empty" class="hidden only:block py-10 text-center text-base-content/60">
          No website policies configured.
        </p>
        <div
          :for={{id, policy} <- @streams.policies}
          id={id}
          class="grid gap-4 py-5 lg:grid-cols-[minmax(0,1fr)_auto] lg:items-start"
        >
          <div class="min-w-0">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="font-semibold">{policy.site_host}</h2>
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
              <span :if={policy.last_failure_kind}>Last failure: {policy.last_failure_kind}</span>
              <span :if={policy.consecutive_rate_limits > 0}>
                {policy.consecutive_rate_limits} consecutive rate limits
              </span>
              <span :if={policy.backoff_until} class="inline-flex items-center gap-1">
                Backoff until
                <.local_time id={"site-policy-backoff-#{policy.id}"} value={policy.backoff_until} />
              </span>
              <span :if={policy.last_successful_implementation}>
                Last success: {extractor_label(policy.last_successful_implementation)}
              </span>
            </div>
            <p :if={present?(policy.notes)} class="mt-2 text-sm text-base-content/75">
              {policy.notes}
            </p>
          </div>

          <div class="flex flex-wrap gap-2 lg:justify-end">
            <button
              :if={policy.consecutive_rate_limits > 0}
              id={"retry-site-now-#{policy.id}"}
              type="button"
              class="btn btn-sm"
              phx-click="retry_site_now"
              phx-value-id={policy.id}
              phx-disable-with="Trying..."
            >
              <.icon name="hero-arrow-path" class="size-4" /> Try now
            </button>
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
            for={@edit_form}
            id={"edit-site-policy-form-#{policy.id}"}
            phx-submit="update_policy"
            class="grid gap-4 border-t border-base-300 pt-5 lg:col-span-2 lg:grid-cols-2"
          >
            <.input
              id={"edit-site-policy-host-#{policy.id}"}
              field={@edit_form[:site_host]}
              type="text"
              label="Website host"
            />
            <.input
              id={"edit-site-policy-extractor-#{policy.id}"}
              field={@edit_form[:minimum_implementation]}
              type="select"
              label="Starting extractor"
              options={extractor_options(@extractors)}
            />
            <.input
              id={"edit-site-policy-interval-#{policy.id}"}
              field={@edit_form[:minimum_request_interval_ms]}
              type="number"
              label="Minimum request interval (ms)"
            />
            <.input
              id={"edit-site-policy-timeout-#{policy.id}"}
              field={@edit_form[:timeout_ms]}
              type="number"
              label="Extraction timeout (ms)"
            />
            <.input
              id={"edit-site-policy-minimum-text-#{policy.id}"}
              field={@edit_form[:minimum_text_length]}
              type="number"
              label="Minimum text length"
            />
            <.input
              id={"edit-site-policy-escalation-#{policy.id}"}
              field={@edit_form[:escalation_enabled]}
              type="checkbox"
              label="Allow escalation"
            />
            <div class="lg:col-span-2">
              <.input
                id={"edit-site-policy-notes-#{policy.id}"}
                field={@edit_form[:notes]}
                type="textarea"
                label="Notes"
              />
            </div>
            <div class="flex gap-2 lg:col-span-2">
              <.button><.icon name="hero-check" class="size-4" /> Save</.button>
              <button type="button" class="btn" phx-click="cancel_edit">Cancel</button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_new_form(socket) do
    form =
      %SiteExtractionPolicy{}
      |> Content.change_site_extraction_policy()
      |> to_form()

    assign(socket, :form, form)
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

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp retry_site_message(site_host) do
    case Dispatcher.retry_now(site_host) do
      {:started, _pid} -> {:info, "Retrying #{site_host} now"}
      :already_running -> {:info, "#{site_host} already has an extraction running"}
      :empty -> {:info, "No queued articles for #{site_host}"}
      {:error, reason} -> {:error, "Could not retry #{site_host}: #{inspect(reason)}"}
    end
  end
end
