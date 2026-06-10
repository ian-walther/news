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
    self_url = "#{NewspaperWeb.Endpoint.url()}/feeds/#{feed.guid}.xml"

    """
    <?xml version="1.0" encoding="UTF-8"?>
    <rss version="2.0">
      <channel>
        <title>#{xml(feed.title)}</title>
        <description>#{xml(feed.description || feed.title)}</description>
        <link>#{xml(self_url)}</link>
        <lastBuildDate>#{rfc2822(DateTime.utc_now())}</lastBuildDate>
        #{Enum.map_join(items, "\n", &render_item/1)}
      </channel>
    </rss>
    """
  end

  defp render_item(item) do
    """
        <item>
          <guid isPermaLink="false">#{xml(item.rendered_guid)}</guid>
          <title>#{xml(item.rendered_title || "Untitled")}</title>
          <link>#{xml(item.rendered_link_url || "")}</link>
          <pubDate>#{rfc2822(item.rendered_published_at || item.published_at || item.inserted_at)}</pubDate>
          #{optional("author", item.rendered_author)}
          #{categories(item.rendered_categories)}
          <description><![CDATA[#{item.rendered_body || item.rendered_summary || ""}]]></description>
        </item>
    """
  end

  defp optional(_tag, nil), do: ""
  defp optional(_tag, ""), do: ""
  defp optional(tag, value), do: "<#{tag}>#{xml(value)}</#{tag}>"

  defp categories(categories) do
    categories
    |> List.wrap()
    |> Enum.map_join("\n", fn category -> "<category>#{xml(category)}</category>" end)
  end

  defp rfc2822(nil), do: rfc2822(DateTime.utc_now())

  defp rfc2822(%DateTime{} = datetime) do
    Calendar.strftime(datetime, "%a, %d %b %Y %H:%M:%S GMT")
  end

  defp xml(value) do
    value
    |> to_string()
    |> Phoenix.HTML.html_escape()
    |> Phoenix.HTML.safe_to_string()
  end
end
