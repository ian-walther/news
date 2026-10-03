defmodule NewspaperWeb.McpBridgeIntegrationTest do
  @moduledoc """
  The real News MCP server reading this application's real read API.

  The `mcp/` package is built and run under Node on its own HTTP transport,
  pointed at this application's router served on a loopback port, and called
  with MCP `tools/call` requests. Nothing between the MCP client and the
  database is faked, so a contract mismatch between the two layers fails
  here even when each side's own tests pass.

  Two servers run for the module: one with structured results (the default)
  and one with `MCP_RESULT_STRUCTURED=false`.
  """

  use Newspaper.DataCase, async: false

  import Newspaper.BridgeFixtures

  alias Newspaper.Publishing

  @mcp_dir Path.expand("../../../mcp", __DIR__)
  @since "2026-09-30T00:00:00Z"
  @until "2026-10-01T00:00:00Z"
  @window %{since: @since, until: @until}
  @in_window ~U[2026-09-30 12:00:00Z]

  setup_all do
    build_mcp!()
    api = start_read_api!()
    %{structured: start_mcp!(api, "true"), text_only: start_mcp!(api, "false")}
  end

  test "pages a window to its end with cursor-only continuation", ctx do
    %{articles: articles} = fixture!(4, feeds: ["Cars"])
    bodies = Map.new(articles, &{&1.guid, String.duplicate("#{&1.title} body text. ", 60)})
    for article <- articles, do: extract!(article, bodies[article.guid], @in_window)

    for server <- [ctx.structured, ctx.text_only] do
      pages = all_pages(server, Map.put(@window, :max_chars, 2_000))
      assert length(pages) > 1

      for page <- pages do
        refute page["isError"]
        assert String.length(text(page)) <= 2_000
      end

      delivered = Enum.map_join(pages, &text/1)

      for {guid, body} <- bodies do
        assert rebuild(delivered, guid) == body
      end

      assert text(List.last(pages)) =~ "[End of bundle.]"
    end

    # Structured results repeat the continuation facts and never the text.
    first = call(ctx.structured, "get_news_bundle", Map.put(@window, :max_chars, 2_000))
    assert first["structuredContent"]["chars"] == String.length(text(first))
    assert first["structuredContent"]["next_cursor"] == cursor_in(text(first))
    refute Map.has_key?(first["structuredContent"], "text")

    refute Map.has_key?(
             call(ctx.text_only, "get_news_bundle", Map.put(@window, :max_chars, 2_000)),
             "structuredContent"
           )
  end

  test "inherited sizes and malformed cursors are client errors (MCP-IMP-01, MCP-IMP-02)", ctx do
    %{articles: [big | _] = articles} = fixture!(3)
    extract!(big, String.duplicate("A very long article. ", 16_000), @in_window)
    for article <- tl(articles), do: extract!(article, "Short.", @in_window)

    for server <- [ctx.structured, ctx.text_only] do
      bundle = call(server, "get_news_bundle", Map.put(@window, :max_chars, 2_000))
      bundle_cursor = cursor_in(text(bundle))
      index = call(server, "list_articles", Map.put(@window, :limit, 1))
      index_cursor = cursor_in(text(index))

      oversized = tamper(bundle_cursor, &Map.put(&1, "size", 400_000))
      rejected = call(server, "get_news_bundle", %{cursor: oversized})
      assert rejected["isError"]
      assert error(rejected)["code"] == "INVALID_CURSOR"
      assert error(rejected)["message"] =~ "max_chars"

      for {tool, cursor} <- [
            {"get_news_bundle", tamper(bundle_cursor, &Map.put(&1, "size", 0))},
            {"get_news_bundle", tamper(bundle_cursor, &Map.put(&1, "feeds", "not-a-list"))},
            {"get_news_bundle", tamper(bundle_cursor, &Map.put(&1, "since", 42))},
            {"get_news_bundle", tamper(bundle_cursor, &put_in(&1, ["pos", "o"], "far"))},
            {"list_articles", tamper(index_cursor, &Map.put(&1, "size", 301))},
            {"list_articles", tamper(index_cursor, &Map.put(&1, "size", 0))},
            {"list_articles", tamper(index_cursor, &Map.put(&1, "pos", %{}))},
            {"list_articles",
             tamper(index_cursor, &Map.put(&1, "pos", %{"t" => "yesterday", "a" => 0}))},
            {"list_articles", "garbage"}
          ] do
        result = call(server, tool, %{cursor: cursor})
        assert result["isError"]
        assert error(result)["code"] == "INVALID_CURSOR"
      end

      # The untouched cursors still continue, alone or with matching arguments.
      refute call(server, "get_news_bundle", %{cursor: bundle_cursor})["isError"]

      refute call(server, "get_news_bundle", %{cursor: bundle_cursor, max_chars: 2_000})[
               "isError"
             ]

      refute call(server, "list_articles", %{cursor: index_cursor})["isError"]

      mismatch = call(server, "get_news_bundle", %{cursor: bundle_cursor, max_chars: 3_000})
      assert error(mismatch)["code"] == "CURSOR_PARAMETER_MISMATCH"
    end
  end

  test "empty pages obey the budget or fail explicitly (MCP-IMP-03)", ctx do
    %{source: source} = fixture!(1)

    feeds =
      for number <- 1..12 do
        {:ok, feed} =
          Publishing.create_generated_feed(%{
            "title" => String.duplicate("Cars ", 40) <> "#{number}",
            "input_feed_ids" => [source.id]
          })

        feed.id
      end

    for server <- [ctx.structured, ctx.text_only] do
      too_small =
        call(server, "get_news_bundle", Map.merge(@window, %{feeds: feeds, max_chars: 2_000}))

      assert too_small["isError"]
      assert error(too_small)["code"] == "BUDGET_TOO_SMALL"

      for arguments <- [
            Map.merge(@window, %{feeds: feeds, max_chars: 8_000}),
            Map.put(@window, :max_chars, 2_000)
          ] do
        empty = call(server, "get_news_bundle", arguments)
        refute empty["isError"]
        assert text(empty) =~ "No articles were first extracted in this window."
        assert String.length(text(empty)) <= arguments.max_chars
      end
    end

    empty = call(ctx.structured, "get_news_bundle", Map.put(@window, :max_chars, 2_000))
    assert empty["structuredContent"]["chars"] == String.length(text(empty))
    assert empty["structuredContent"]["next_cursor"] == nil
  end

  test "fractional-second bounds select by the instant given (MCP-IMP-04)", ctx do
    %{articles: [noon | later]} = fixture!(4)
    extract!(noon, "Extracted exactly at noon.", ~U[2026-09-30 12:00:00Z])

    for article <- later do
      extract!(article, String.duplicate("Later text. ", 150), ~U[2026-09-30 18:00:00Z])
    end

    for server <- [ctx.structured, ctx.text_only] do
      after_noon = all_pages(server, %{since: "2026-09-30T12:00:00.500Z", until: @until})
      refute Enum.map_join(after_noon, &text/1) =~ noon.guid

      through_noon = all_pages(server, %{since: @since, until: "2026-09-30T12:00:00.500Z"})
      assert Enum.map_join(through_noon, &text/1) =~ "Extracted exactly at noon."

      # The same instant in another offset.
      shifted = all_pages(server, %{since: @since, until: "2026-09-30T08:00:00.500-04:00"})
      assert Enum.map_join(shifted, &text/1) =~ "Extracted exactly at noon."

      before_noon = all_pages(server, %{since: @since, until: "2026-09-30T12:00:00Z"})
      refute Enum.map_join(before_noon, &text/1) =~ noon.guid

      # A cursor carries the fractional bound, and tells it from a nearby one.
      arguments = %{since: @since, until: "2026-09-30T23:59:59.250Z", max_chars: 2_000}
      first = call(server, "get_news_bundle", arguments)
      cursor = cursor_in(text(first))
      second = call(server, "get_news_bundle", %{cursor: cursor})
      refute second["isError"]
      assert text(second) =~ "2026-09-30T23:59:59.250Z)"

      other = call(server, "get_news_bundle", %{cursor: cursor, until: "2026-09-30T23:59:59Z"})
      assert error(other)["code"] == "CURSOR_PARAMETER_MISMATCH"
    end
  end

  test "every factual timestamp reaches the MCP client (MCP-IMP-05)", ctx do
    %{articles: [article]} = fixture!(1, feeds: ["Cars"])
    set_published!(article, ~U[2026-09-30 06:01:00Z])
    set_first_seen!(article, ~U[2026-09-30 12:00:11Z])
    extract!(article, "The original body.", ~U[2026-09-30 12:00:30Z])
    reextract!(article, "The body, extracted again.", ~U[2026-09-30 12:00:42Z])

    for server <- [ctx.structured, ctx.text_only] do
      index = call(server, "list_articles", @window)
      refute index["isError"]

      for fact <- [
            "published 2026-09-30T06:01:00Z",
            "first seen 2026-09-30T12:00:11Z",
            "first extracted 2026-09-30T12:00:30Z",
            "latest extraction 2026-09-30T12:00:42Z"
          ] do
        assert text(index) =~ fact
      end

      # The index stays body-free.
      refute text(index) =~ "extracted again"

      for result <- [
            call(server, "get_news_bundle", @window),
            call(server, "get_article", %{guid: article.guid})
          ] do
        assert text(result) =~ "Published: 2026-09-30T06:01:00Z"
        assert text(result) =~ "First extracted: 2026-09-30T12:00:30Z"
        assert text(result) =~ "Latest extraction: 2026-09-30T12:00:42Z"
        assert text(result) =~ "The body, extracted again."
      end
    end

    structured = call(ctx.structured, "list_articles", @window)["structuredContent"]
    assert structured["totals"]["readable"] == 1
    assert structured["window"] == %{"since" => @since, "until" => @until}
    refute Map.has_key?(call(ctx.text_only, "list_articles", @window), "structuredContent")
  end

  test "text-only mode covers error results too (MCP-IMP-06)", ctx do
    fixture!(1)

    failures = [
      {"NOT_FOUND", "get_article", %{guid: "art_missing"}},
      {"INVALID_PARAMETER", "list_articles", %{since: @until, until: @since}},
      {"INVALID_PARAMETER", "get_news_bundle", %{since: "yesterday"}},
      {"INVALID_CURSOR", "get_news_bundle", %{cursor: "garbage"}}
    ]

    for {code, tool, arguments} <- failures do
      plain = call(ctx.text_only, tool, arguments)
      assert plain["isError"]
      refute Map.has_key?(plain, "structuredContent")
      assert error(plain)["code"] == code

      structured = call(ctx.structured, tool, arguments)
      assert structured["isError"]
      assert structured["structuredContent"]["error"]["code"] == code
      assert error(structured) == structured["structuredContent"]["error"]
    end

    # Arguments the MCP schema rejects never reach the application.
    for server <- [ctx.structured, ctx.text_only] do
      rejected = call(server, "get_article", %{guid: "../../etc/passwd"})
      assert rejected["isError"]
      refute Map.has_key?(rejected, "structuredContent")
    end
  end

  # --- MCP client ------------------------------------------------------------

  defp call(server, tool, arguments) do
    response =
      Req.post!(server,
        json: %{
          jsonrpc: "2.0",
          id: 1,
          method: "tools/call",
          params: %{name: tool, arguments: arguments}
        },
        headers: [{"accept", "application/json, text/event-stream"}],
        retry: false
      )

    assert response.status == 200
    assert %{"result" => result} = message(response.body)
    result
  end

  # The transport may answer with plain JSON or with one server-sent event.
  defp message(%{} = body), do: body

  defp message(body) when is_binary(body) do
    assert [_line, data] = Regex.run(~r/^data: (.+)$/m, body)
    Jason.decode!(data)
  end

  defp all_pages(server, arguments) do
    Stream.unfold(arguments, fn
      nil ->
        nil

      arguments ->
        page = call(server, "get_news_bundle", arguments)
        refute page["isError"]
        cursor = cursor_in(text(page))
        {page, cursor && %{cursor: cursor}}
    end)
    |> Enum.to_list()
  end

  defp text(%{"content" => [%{"type" => "text", "text" => text}]}), do: text

  defp error(result), do: result |> text() |> Jason.decode!() |> Map.fetch!("error")

  # The cursor as an agent reads it: from the closing line of the text.
  defp cursor_in(text) do
    case Regex.run(~r/cursor: ([A-Za-z0-9_-]+)\]\z/, text) do
      [_line, cursor] -> cursor
      nil -> nil
    end
  end

  # One article's text, reassembled from every part delivered for it.
  defp rebuild(delivered, guid) do
    delivered
    |> String.split("\n===== ARTICLE #{guid} =====\n")
    |> tl()
    |> Enum.map_join(fn block ->
      [block, _after] = String.split(block, "\n===== END #{guid} =====\n", parts: 2)
      [_header, body] = String.split(block, "\n\n", parts: 2)
      body
    end)
  end

  # --- processes -------------------------------------------------------------

  defp build_mcp! do
    unless File.dir?(Path.join(@mcp_dir, "node_modules")), do: npm!(["ci"])
    npm!(["run", "build"])
  end

  defp npm!(args) do
    case System.cmd("npm", args, cd: @mcp_dir, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> raise "npm #{Enum.join(args, " ")} exited #{status}:\n#{output}"
    end
  end

  # This application's router on a real loopback port.
  defp start_read_api! do
    server =
      start_supervised!(
        {Bandit, plug: NewspaperWeb.Endpoint, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp start_mcp!(api, structured) do
    env = %{
      "NEWS_API_URL" => api,
      "MCP_HTTP_HOST" => "127.0.0.1",
      "MCP_HTTP_PORT" => "0",
      "MCP_AUTH_MODE" => "none",
      "MCP_HTTP_RESPONSE_MODE" => "json",
      "MCP_RESULT_STRUCTURED" => structured,
      "MCP_RATE_LIMIT_PER_MINUTE" => "0",
      "MCP_AUDIT_ENABLED" => "false",
      "LOG_FORMAT" => "json",
      "LOG_LEVEL" => "info"
    }

    port =
      Port.open({:spawn_executable, System.find_executable("node")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 65_536},
        args: ["dist/http.js"],
        cd: @mcp_dir,
        env: Enum.map(env, fn {name, value} -> {to_charlist(name), to_charlist(value)} end)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> System.cmd("kill", [Integer.to_string(os_pid)], stderr_to_stdout: true) end)

    await_listening(port, [])
  end

  defp await_listening(port, seen) do
    receive do
      {^port, {:data, {_flag, line}}} ->
        case Jason.decode(line) do
          {:ok, %{"url" => url}} -> url
          _other -> await_listening(port, [line | seen])
        end

      {^port, {:exit_status, status}} ->
        raise "the MCP server exited #{status} before listening:\n" <>
                (seen |> Enum.reverse() |> Enum.join("\n"))
    after
      30_000 -> raise "the MCP server did not start listening within 30 seconds"
    end
  end
end
