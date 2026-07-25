defmodule NewspaperWeb.FeedController do
  use NewspaperWeb, :controller

  alias Newspaper.Publishing

  def show(conn, %{"path" => [feed_path]}) do
    guid = String.replace_suffix(feed_path, ".xml", "")

    case Publishing.get_generated_feed_by_guid(guid) do
      nil ->
        send_resp(conn, 404, "Not found")

      feed ->
        items = Publishing.list_recent_items(feed)

        conn
        |> put_resp_content_type("application/rss+xml")
        |> text(render_feed(conn, feed, items))
    end
  end

  def show(conn, _params), do: send_resp(conn, 404, "Not found")

  defp render_feed(_conn, feed, items) do
    base_url = NewspaperWeb.Endpoint.url()
    self_url = "#{base_url}/feeds/#{feed.guid}.xml"

    rss =
      Saxy.XML.element(
        "rss",
        [
          {"version", "2.0"},
          {"xmlns:dc", "http://purl.org/dc/elements/1.1/"},
          {"xmlns:atom", "http://www.w3.org/2005/Atom"}
        ],
        [
          Saxy.XML.element("channel", [], [
            text_element("title", feed.title),
            text_element("description", feed.description || feed.title),
            text_element("link", base_url),
            Saxy.XML.empty_element(
              "atom:link",
              [{"href", self_url}, {"rel", "self"}, {"type", "application/rss+xml"}]
            ),
            text_element("lastBuildDate", rfc2822(DateTime.utc_now())),
            Enum.map(items, &render_item(&1, base_url))
          ])
        ]
      )

    Saxy.encode!(rss, version: "1.0", encoding: "UTF-8")
  end

  defp render_item(item, base_url) do
    Saxy.XML.element("item", [], [
      Saxy.XML.element(
        "guid",
        [{"isPermaLink", "false"}],
        Saxy.XML.characters(item.rendered_guid)
      ),
      text_element("title", item.rendered_title || "Untitled"),
      text_element("link", absolute_url(item.rendered_link_url, base_url)),
      optional(
        "pubDate",
        optional_rfc2822(item.rendered_published_at || item.published_at)
      ),
      optional("dc:creator", item.rendered_author),
      categories(item.rendered_categories),
      enclosures(item.rendered_media),
      text_element("description", item.rendered_body || item.rendered_summary || "")
    ])
  end

  defp optional(_tag, nil), do: []
  defp optional(_tag, ""), do: []
  defp optional(tag, value), do: text_element(tag, value)

  defp categories(categories) do
    categories
    |> List.wrap()
    |> Enum.map(&text_element("category", &1))
  end

  defp enclosures(media) do
    media
    |> Kernel.||(%{})
    |> Map.get("enclosures", [])
    |> List.wrap()
    |> Enum.map(fn enclosure ->
      attributes =
        [
          {"url", enclosure["url"]},
          {"type", enclosure["type"]},
          {"length", enclosure["length"]}
        ]
        |> Enum.reject(fn {_name, value} -> is_nil(value) or value == "" end)

      Saxy.XML.empty_element("enclosure", attributes)
    end)
  end

  defp text_element(tag, value) do
    Saxy.XML.element(tag, [], Saxy.XML.characters(value || ""))
  end

  defp absolute_url(nil, _base_url), do: ""
  defp absolute_url("", _base_url), do: ""

  defp absolute_url(url, base_url) do
    case URI.parse(url) do
      %URI{scheme: nil} -> base_url |> URI.merge(url) |> URI.to_string()
      _uri -> url
    end
  end

  defp optional_rfc2822(nil), do: nil
  defp optional_rfc2822(datetime), do: rfc2822(datetime)

  defp rfc2822(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end
end
