defmodule NewspaperWeb.AdminLive.Nav do
  use NewspaperWeb, :html

  def nav(assigns) do
    ~H"""
    <nav class="mb-6 flex gap-4 text-sm">
      <.link navigate={~p"/"}>Activity</.link>
      <.link navigate={~p"/intake"}>Intake</.link>
      <.link navigate={~p"/output-feeds"}>Output Feeds</.link>
      <.link navigate={~p"/articles"}>Articles</.link>
      <.link navigate={~p"/runs"}>Runs</.link>
      <.link navigate={~p"/settings"}>Settings</.link>
    </nav>
    """
  end
end
