defmodule Newspaper.Bridge.Cursor do
  @moduledoc """
  Opaque continuation tokens for the bridge. A cursor carries the resolved
  request it was issued for (window, feed selection, size) and a position.
  It is not signed: it grants nothing the caller could not ask for directly.
  """

  @version 1

  def encode(kind, request, position) do
    %{
      "v" => @version,
      "k" => kind,
      "since" => DateTime.to_iso8601(request.since),
      "until" => DateTime.to_iso8601(request.until),
      "feeds" => request.feeds,
      "size" => request.size,
      "pos" => position
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  def decode(kind, token) when is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, %{"v" => @version, "k" => ^kind} = cursor} <- Jason.decode(json),
         {:ok, since, _} <- DateTime.from_iso8601(cursor["since"] || ""),
         {:ok, until, _} <- DateTime.from_iso8601(cursor["until"] || ""),
         true <- is_nil(cursor["feeds"]) or Enum.all?(cursor["feeds"], &is_integer/1),
         true <- is_integer(cursor["size"]),
         true <- is_map(cursor["pos"]) do
      {:ok,
       %{
         since: since,
         until: until,
         feeds: cursor["feeds"],
         size: cursor["size"],
         pos: cursor["pos"]
       }}
    else
      _ -> :error
    end
  end

  def decode(_kind, _token), do: :error
end
