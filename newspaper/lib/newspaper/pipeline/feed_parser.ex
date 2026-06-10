defmodule Newspaper.Pipeline.FeedParser do
  @moduledoc false

  def parse(xml) when is_binary(xml) do
    with {:ok, feed} <- Fiet.parse(xml) do
      {:ok, map_feed(feed)}
    end
  end

  defp map_feed(feed) do
    %{
      title: feed.title,
      link: feed.link,
      description: feed.description,
      updated_at: parse_datetime(feed.updated_at),
      categories: feed.categories || [],
      items: Enum.map(feed.items || [], &map_item(feed, &1)),
      raw_metadata: stringify(feed)
    }
  end

  defp map_item(feed, item) do
    %{
      feed_guid: blank_to_nil(item.id),
      url: blank_to_nil(item.link),
      title: item.title,
      author: nil,
      published_at: parse_datetime(item.published_at),
      feed_updated_at: nil,
      body: item.description,
      summary: item.description,
      source_url: feed.link,
      source_name: feed.title,
      categories: [],
      media: %{},
      raw_metadata: stringify(item)
    }
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    with {:error, _} <- DateTime.from_iso8601(value),
         {:error, _} <- parse_rfc1123(value) do
      nil
    else
      {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
      {:ok, datetime} -> DateTime.truncate(datetime, :second)
    end
  end

  defp parse_datetime(_value), do: nil

  defp parse_rfc1123(value) do
    case :httpd_util.convert_request_date(String.to_charlist(value)) do
      :bad_date ->
        {:error, :bad_date}

      {{year, month, day}, {hour, minute, second}} ->
        DateTime.new(Date.new!(year, month, day), Time.new!(hour, minute, second), "Etc/UTC")
    end
  end

  defp stringify(struct) do
    struct
    |> Map.from_struct()
    |> Jason.encode!()
    |> Jason.decode!()
  rescue
    _ -> %{"inspect" => inspect(struct)}
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
