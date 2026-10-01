defmodule Newspaper.Bridge.Splitter do
  @moduledoc """
  Lossless text splitting for bridge pages. `take/2` removes up to `limit`
  characters (Elixir `String.length/1` units) from the front of a text at
  the best available boundary: paragraph, then sentence, then whitespace,
  then a hard cut. The chunk and the rest always concatenate back to the
  original text, and the cut is always on a grapheme boundary so character
  offsets stay exact across parts.
  """

  @paragraph ["\n\n"]
  @sentence [". ", "! ", "? ", ".\n", "!\n", "?\n", "\n"]
  @whitespace [" ", "\t"]

  def take(text, limit) when is_binary(text) and is_integer(limit) and limit >= 1 do
    {prefix, rest} = String.split_at(text, limit)

    if rest == "" do
      {text, ""}
    else
      cut = boundary(prefix)
      <<chunk::binary-size(^cut), tail::binary>> = prefix

      # A boundary that would divide a grapheme cluster is not used.
      if aligned?(prefix, chunk), do: {chunk, tail <> rest}, else: {prefix, rest}
    end
  end

  @doc "Number of parts `take/2` produces for `text` at `limit` characters each."
  def count_parts("", _limit), do: 0

  def count_parts(text, limit) do
    {_chunk, rest} = take(text, limit)
    1 + count_parts(rest, limit)
  end

  defp boundary(prefix) do
    size = byte_size(prefix)
    floor = div(size, 2)

    last_cut(prefix, @paragraph, floor) || last_cut(prefix, @sentence, floor) ||
      last_cut(prefix, @whitespace, floor) || size
  end

  # The last boundary in the second half of the window; an earlier one would
  # waste most of the page.
  defp last_cut(prefix, patterns, floor) do
    case :binary.matches(prefix, patterns) do
      [] ->
        nil

      matches ->
        {position, length} = List.last(matches)
        cut = position + length
        if cut > floor, do: cut
    end
  end

  defp aligned?(prefix, chunk) do
    {head, _tail} = String.split_at(prefix, String.length(chunk))
    head == chunk
  end
end
