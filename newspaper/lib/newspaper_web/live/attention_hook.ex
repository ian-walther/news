defmodule NewspaperWeb.AttentionHook do
  @moduledoc """
  Gives every admin LiveView a reactive `@attention_count` from the shared
  counter, so the navigation badge is live on every page without each view
  querying anything (audit IMP-13).
  """

  import Phoenix.Component
  import Phoenix.LiveView

  alias Newspaper.Operations.AttentionCounter

  def on_mount(:default, _params, _session, socket) do
    if connected?(socket), do: AttentionCounter.subscribe()

    socket =
      socket
      |> assign(:attention_count, AttentionCounter.current())
      |> attach_hook(:attention_count, :handle_info, fn
        {:attention_count, count}, socket -> {:halt, assign(socket, :attention_count, count)}
        _message, socket -> {:cont, socket}
      end)

    {:cont, socket}
  end
end
