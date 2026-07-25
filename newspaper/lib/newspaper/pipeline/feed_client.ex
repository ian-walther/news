defmodule Newspaper.Pipeline.FeedClient do
  @moduledoc false

  alias Newspaper.Intake.InputFeed

  def get(%InputFeed{} = feed) do
    headers =
      [
        {"user-agent", "Newspaper/0.1 (+http://news.home)"}
      ]
      |> maybe_add_header("if-none-match", feed.etag)
      |> maybe_add_header("if-modified-since", feed.last_modified)

    options =
      [
        headers: headers,
        receive_timeout: 30_000,
        retry: false
      ]
      |> Keyword.merge(Application.get_env(:newspaper, :feed_req_options, []))

    Req.get(feed.url, options)
  end

  defp maybe_add_header(headers, _name, value) when value in [nil, ""], do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]
end
