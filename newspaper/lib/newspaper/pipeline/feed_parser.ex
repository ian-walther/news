defmodule Newspaper.Pipeline.FeedParser do
  @moduledoc false

  def parse(xml) when is_binary(xml) do
    case Newspaper.Pipeline.RSS2Parser.parse(xml) do
      {:ok, feed} ->
        {:ok, map_rss_feed(feed)}

      {:error, _rss_error} ->
        case Fiet.Atom.parse(xml) do
          {:ok, feed} ->
            entry_metadata = Newspaper.Pipeline.AtomEntryMetadataParser.parse(xml)
            {:ok, map_atom_feed(feed, entry_metadata)}

          {:error, atom_error} ->
            {:error, atom_error}
        end
    end
  end

  defp map_rss_feed(feed) do
    %{
      title: feed.title,
      link: feed.link,
      description: feed.description,
      updated_at: parse_datetime(feed.last_build_date || feed.pub_date),
      categories: rss_categories(feed.categories),
      items: Enum.map(feed.items || [], &map_rss_item(feed, &1)),
      raw_metadata: normalize_metadata(feed)
    }
  end

  defp map_rss_item(feed, item) do
    content = extra_content(item.extras, :content_encoded)

    %{
      feed_guid: blank_to_nil(item.guid),
      url: blank_to_nil(item.link),
      title: item.title,
      author: extra_content(item.extras, :dc_creator) || item.author,
      published_at: parse_datetime(item.pub_date),
      feed_updated_at:
        parse_datetime(
          extra_content(item.extras, :dc_date) ||
            extra_content(item.extras, :updated) ||
            extra_content(item.extras, :atom_updated)
        ),
      body: present_value(content) || item.description,
      summary: item.description,
      source_url: feed.link,
      source_name: feed.title,
      categories: rss_categories(item.categories),
      media: rss_media(item),
      raw_metadata: normalize_metadata(item)
    }
  end

  defp map_atom_feed(feed, entry_metadata) do
    %{
      title: text_construct(feed.title),
      link: atom_link(feed.links, ["alternate", nil]),
      description: text_construct(feed.subtitle),
      updated_at: parse_datetime(feed.updated),
      categories: atom_categories(feed.categories),
      items:
        Enum.map(feed.entries || [], fn item ->
          map_atom_item(feed, item, Map.get(entry_metadata, item.id, []))
        end),
      raw_metadata: normalize_metadata(feed)
    }
  end

  defp map_atom_item(feed, item, supplemental_categories) do
    summary = text_construct(item.summary)
    categories = if item.categories == [], do: supplemental_categories, else: item.categories

    %{
      feed_guid: blank_to_nil(item.id),
      url: atom_link(item.links, ["alternate", nil]),
      title: text_construct(item.title),
      author: atom_author(item.authors),
      published_at: parse_datetime(item.published || item.updated),
      feed_updated_at: parse_datetime(item.updated),
      body: present_value(text_construct(item.content)) || summary,
      summary: summary,
      source_url: atom_link(feed.links, ["alternate", nil]),
      source_name: text_construct(feed.title),
      categories: atom_categories(categories),
      media: atom_media(item.links),
      raw_metadata:
        item
        |> normalize_metadata()
        |> Map.put("categories", normalize_metadata(categories))
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

  defp rss_categories(categories) do
    categories
    |> List.wrap()
    |> Enum.reverse()
    |> Enum.map(& &1.value)
    |> Enum.reject(&blank?/1)
  end

  defp atom_categories(categories) do
    categories
    |> List.wrap()
    |> Enum.map(fn
      %{term: term} -> term
      %{"term" => term} -> term
    end)
    |> Enum.reject(&blank?/1)
  end

  defp rss_media(%{enclosure: nil}), do: %{}

  defp rss_media(%{enclosure: enclosure}) do
    %{
      "enclosures" => [
        %{
          "url" => enclosure.url,
          "type" => enclosure.type,
          "length" => enclosure.length
        }
      ]
    }
  end

  defp atom_media(links) do
    enclosures =
      links
      |> List.wrap()
      |> Enum.filter(&(&1.rel == "enclosure" and present?(&1.href)))
      |> Enum.map(fn link ->
        %{"url" => link.href, "type" => link.type, "length" => link.length}
      end)

    if enclosures == [], do: %{}, else: %{"enclosures" => enclosures}
  end

  defp atom_link(links, accepted_relations) do
    links
    |> List.wrap()
    |> Enum.find_value(fn link ->
      if link.rel in accepted_relations and present?(link.href), do: link.href
    end)
  end

  defp atom_author(authors) do
    authors
    |> List.wrap()
    |> List.first()
    |> case do
      nil -> nil
      author -> present_value(author.name) || present_value(author.email)
    end
  end

  defp text_construct({_type, content}), do: content
  defp text_construct(nil), do: nil

  defp extra_content(extras, key) do
    case Map.get(extras || %{}, key) do
      {_attributes, content} -> present_value(content)
      _other -> nil
    end
  end

  defp normalize_metadata(%_{} = struct) do
    struct
    |> Map.from_struct()
    |> normalize_metadata()
  end

  defp normalize_metadata(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_metadata(value)} end)
  end

  defp normalize_metadata(list) when is_list(list), do: Enum.map(list, &normalize_metadata/1)

  defp normalize_metadata(tuple) when is_tuple(tuple) do
    case tuple do
      {type, content} when is_atom(type) ->
        %{"type" => Atom.to_string(type), "content" => normalize_metadata(content)}

      _other ->
        tuple |> Tuple.to_list() |> normalize_metadata()
    end
  end

  defp normalize_metadata(value), do: value

  defp present_value(value), do: if(present?(value), do: value)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp blank?(value), do: not present?(value)
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value
end
