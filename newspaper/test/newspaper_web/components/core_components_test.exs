defmodule NewspaperWeb.CoreComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias NewspaperWeb.CoreComponents

  test "local time uses the globally registered browser hook" do
    html =
      render_component(&CoreComponents.local_time/1,
        id: "local-time-test",
        value: ~U[2026-07-16 12:00:00Z]
      )

    assert html =~ ~s(phx-hook="LocalTime")
  end
end
