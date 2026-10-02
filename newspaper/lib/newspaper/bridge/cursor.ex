defmodule Newspaper.Bridge.Cursor do
  @moduledoc """
  Opaque continuation tokens for the bridge. A cursor carries the resolved
  request it was issued for (window, feed selection, size) and a position.

  It is not signed: it grants nothing the caller could not ask for directly.
  Its contents are therefore untrusted arguments. `decode/2` is total: every
  field is checked for type and range, and anything unexpected is `:error`,
  never an exception. The size is range-checked by the caller, which knows
  the limits currently configured for the cursor's kind.
  """

  @version 1

  # Positions never legitimately exceed these, and the continuation line is
  # reserved at their widths (see `widest_position/1`).
  @max_id 9_223_372_036_854_775_807
  @max_unix 99_999_999_999
  @max_offset 999_999_999

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

  def decode(kind, token) when kind in ["bundle", "index"] and is_binary(token) do
    with {:ok, json} <- Base.url_decode64(token, padding: false),
         {:ok, %{"v" => @version, "k" => ^kind} = cursor} <- Jason.decode(json),
         {:ok, since} <- time(cursor["since"]),
         {:ok, until} <- time(cursor["until"]),
         :lt <- DateTime.compare(since, until),
         {:ok, feeds} <- feeds(cursor["feeds"]),
         {:ok, size} <- integer(cursor["size"], -@max_id, @max_id),
         {:ok, pos} <- position(kind, cursor["pos"]) do
      {:ok, %{since: since, until: until, feeds: feeds, size: size, pos: pos}}
    else
      _other -> :error
    end
  end

  def decode(_kind, _token), do: :error

  @doc "The position that encodes to the longest token, for reserving the continuation line."
  def widest_position("bundle") do
    %{"f" => @max_id, "t" => -@max_unix, "a" => @max_id, "o" => @max_offset, "p" => @max_offset}
  end

  @doc """
  Whether an ISO-8601 time keeps its meaning when parsed: `DateTime` holds
  microseconds and would silently drop anything finer.
  """
  def representable_precision?(value) when is_binary(value),
    do: not Regex.match?(~r/[.,]\d{7,}/, value)

  defp time(value) when is_binary(value) do
    with true <- representable_precision?(value),
         {:ok, time, _offset} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _other -> :error
    end
  end

  defp time(_value), do: :error

  defp feeds(nil), do: {:ok, nil}

  # Stored sorted and unique; any other shape was not issued by the bridge.
  defp feeds([_ | _] = ids) do
    if Enum.all?(ids, &id?/1) and ids == ids |> Enum.uniq() |> Enum.sort(),
      do: {:ok, ids},
      else: :error
  end

  defp feeds(_value), do: :error

  # Bundle: feed and article of the next entry, its sort time (unix seconds),
  # and how far into its text the previous page got. Part N starts at an
  # offset of at least N - 1 characters, and offset 0 is always part 1.
  defp position("bundle", %{"t" => time, "a" => article, "o" => offset, "p" => part} = pos)
       when map_size(pos) == 5 and is_map_key(pos, "f") do
    with true <- is_nil(pos["f"]) or id?(pos["f"]),
         {:ok, time} <- integer(time, -@max_unix, @max_unix),
         true <- id?(article),
         {:ok, offset} <- integer(offset, 0, @max_offset),
         {:ok, part} <- integer(part, 1, offset + 1),
         true <- offset == 0 or part > 1 do
      {:ok, %{"f" => pos["f"], "t" => time, "a" => article, "o" => offset, "p" => part}}
    else
      _other -> :error
    end
  end

  # Index: the sort time and id of the last article on the previous page.
  defp position("index", %{"t" => time, "a" => article} = pos) when map_size(pos) == 2 do
    with {:ok, time} <- time(time),
         true <- id?(article) do
      {:ok, %{"t" => time, "a" => article}}
    else
      _other -> :error
    end
  end

  defp position(_kind, _pos), do: :error

  defp id?(value), do: is_integer(value) and value >= 1 and value <= @max_id

  defp integer(value, min, max) when is_integer(value) and value >= min and value <= max,
    do: {:ok, value}

  defp integer(_value, _min, _max), do: :error
end
