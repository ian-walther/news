defmodule NewspaperWeb.BridgeController do
  @moduledoc """
  JSON read API consumed by the News MCP server. It has no authentication of
  its own: it sits at the same LAN trust level as the rest of the
  application, and the MCP server in front of it is the OAuth boundary.
  """

  use NewspaperWeb, :controller

  alias Newspaper.Bridge

  def feeds(conn, _params), do: respond(conn, Bridge.feeds())
  def articles(conn, params), do: respond(conn, Bridge.index(params))
  def bundle(conn, params), do: respond(conn, Bridge.bundle(params))
  def article(conn, %{"guid" => guid} = params), do: respond(conn, Bridge.article(guid, params))

  defp respond(conn, {:ok, payload}), do: json(conn, payload)

  defp respond(conn, {:error, {code, message}}) do
    conn
    |> put_status(status(code))
    |> json(%{error: %{code: code, message: message}})
  end

  defp status(:not_found), do: :not_found
  defp status(:budget_too_small), do: :unprocessable_entity
  defp status(_code), do: :bad_request
end
