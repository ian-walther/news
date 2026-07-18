defmodule NewspaperWeb.AdminLive.Nav do
  use NewspaperWeb, :html

  attr :current, :string, required: true

  def nav(assigns) do
    assigns = assign(assigns, :items, nav_items())

    ~H"""
    <nav id="app-nav" class="mb-8 border-b border-base-300" aria-label="Primary navigation">
      <div class="flex flex-col gap-3 sm:flex-row sm:items-end sm:justify-between">
        <.link navigate={~p"/"} class="flex shrink-0 items-center gap-2 pb-3 font-semibold">
          <span class="grid size-7 place-items-center bg-primary text-xs font-bold text-primary-content">
            N
          </span>
          Newspaper
        </.link>

        <div
          id="app-nav-scroll"
          class="flex max-w-full gap-1 overflow-x-auto pb-2 sm:justify-end"
        >
          <.link
            :for={item <- @items}
            navigate={item.path}
            data-nav={item.key}
            aria-current={if(@current == item.key, do: "page")}
            class={[
              "btn btn-sm shrink-0 gap-1.5 border-0",
              @current == item.key && "btn-primary",
              @current != item.key && "btn-ghost text-base-content/65"
            ]}
          >
            <.icon name={item.icon} class="size-4" /> {item.label}
          </.link>
        </div>
      </div>
    </nav>
    """
  end

  defp nav_items do
    [
      %{key: "activity", label: "Activity", path: ~p"/", icon: "hero-chart-bar"},
      %{key: "intake", label: "Intake", path: ~p"/intake", icon: "hero-arrow-down-tray"},
      %{
        key: "output-feeds",
        label: "Outputs",
        path: ~p"/output-feeds",
        icon: "hero-rss"
      },
      %{key: "articles", label: "Articles", path: ~p"/articles", icon: "hero-newspaper"},
      %{key: "sites", label: "Sites", path: ~p"/sites", icon: "hero-globe-alt"},
      %{
        key: "processing",
        label: "Processing",
        path: ~p"/processing",
        icon: "hero-queue-list"
      },
      %{key: "settings", label: "Settings", path: ~p"/settings", icon: "hero-cog-6-tooth"}
    ]
  end
end
