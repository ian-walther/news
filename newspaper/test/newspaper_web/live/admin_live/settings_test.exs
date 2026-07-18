defmodule NewspaperWeb.AdminLive.SettingsTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Operations

  test "discovers and saves the global Ollama model", %{conn: conn} do
    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      Req.Test.json(conn, %{
        "models" => [
          %{"name" => "qwen3.6:27b"},
          %{"name" => "gpt-oss:20b"}
        ]
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#settings-form input[name='app_settings[ollama_base_url]']")
    assert has_element?(view, "#settings-form select[name='app_settings[ollama_model]']")
    assert has_element?(view, "#settings-form option[value='qwen3.6:27b']")
    assert has_element?(view, "#ollama-connection-status", "2 models available")

    view
    |> form("#settings-form", %{
      "app_settings" => %{
        "fetch_interval_minutes" => "60",
        "run_history_enabled" => "true",
        "ollama_base_url" => "http://desktop.home:11434",
        "ollama_model" => "qwen3.6:27b"
      }
    })
    |> render_submit()

    settings = Operations.get_settings()
    assert settings.ollama_base_url == "http://desktop.home:11434"
    assert settings.ollama_model == "qwen3.6:27b"
  end

  test "preserves a saved model when discovery is unavailable", %{conn: conn} do
    settings = Operations.get_settings()

    assert {:ok, _settings} =
             Operations.update_settings(settings, %{
               ollama_model: "qwen3.6:27b"
             })

    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      Plug.Conn.send_resp(conn, 503, "offline")
    end)

    {:ok, view, _html} = live(conn, ~p"/settings")
    _ = :sys.get_state(view.pid)

    assert has_element?(view, "#settings-form option[value='qwen3.6:27b'][selected]")
    assert has_element?(view, "#ollama-connection-status", "Unavailable")
  end
end
