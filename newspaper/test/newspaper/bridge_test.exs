defmodule Newspaper.BridgeTest do
  use Newspaper.DataCase

  import Newspaper.BridgeFixtures

  alias Newspaper.Bridge
  alias Newspaper.Bridge.Splitter
  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Publishing
  alias Newspaper.Publishing.GeneratedFeedItem

  @since "2026-09-30T00:00:00Z"
  @until "2026-10-01T00:00:00Z"
  @in_window ~U[2026-09-30 12:00:00Z]

  describe "Splitter.take/2" do
    test "prefers paragraph, then sentence, then whitespace, then a hard cut, and never loses text" do
      paragraphs =
        String.duplicate("alpha beta. ", 20) <> "\n\n" <> String.duplicate("gamma delta. ", 20)

      {chunk, rest} = Splitter.take(paragraphs, 300)
      assert String.ends_with?(chunk, "\n\n")
      assert chunk <> rest == paragraphs

      sentences = String.duplicate("One sentence here. ", 40)
      {chunk, rest} = Splitter.take(sentences, 100)
      assert String.ends_with?(chunk, ". ")
      assert chunk <> rest == sentences

      words = String.duplicate("word ", 100)
      {chunk, rest} = Splitter.take(words, 52)
      assert String.ends_with?(chunk, " ")
      assert chunk <> rest == words

      solid = String.duplicate("x", 500)
      assert {chunk, rest} = Splitter.take(solid, 120)
      assert String.length(chunk) == 120
      assert chunk <> rest == solid
    end

    test "keeps grapheme clusters whole in non-ASCII text" do
      family = "👨‍👩‍👧‍👦"
      text = String.duplicate("日本語のテキスト" <> family <> "é", 60)
      parts = split_all(text, 37)

      assert Enum.join(parts) == text
      assert Enum.all?(parts, &(String.length(&1) <= 37))
      assert Enum.sum(Enum.map(parts, &String.length/1)) == String.length(text)
    end
  end

  describe "window" do
    test "uses the first successful extraction and half-open bounds" do
      %{articles: [old, at_since, at_until, reextracted]} = fixture!(4)

      # Published long ago, first extracted inside the window: readable now.
      extract!(old, "Late extraction of an old article.", @in_window)
      set_published!(old, ~U[2026-01-05 08:00:00Z])
      extract!(at_since, "Exactly at the lower bound.", ~U[2026-09-30 00:00:00Z])
      extract!(at_until, "Exactly at the upper bound.", ~U[2026-10-01 00:00:00Z])

      # First extracted the day before, re-extracted inside the window.
      extract!(reextracted, "Original text.", ~U[2026-09-29 09:00:00Z])
      reextract!(reextracted, "Replaced text.", @in_window)

      assert bundle_guids(%{"since" => @since, "until" => @until}) ==
               Enum.sort([old.guid, at_since.guid])

      assert bundle_guids(%{"since" => "2026-09-29T00:00:00Z", "until" => @since}) ==
               [reextracted.guid]

      assert bundle_guids(%{"since" => @until, "until" => "2026-10-02T00:00:00Z"}) ==
               [at_until.guid]
    end

    test "accepts explicit offsets and refuses times without one or reversed windows" do
      %{articles: [article]} = fixture!(1)
      extract!(article, "Body.", @in_window)

      assert bundle_guids(%{"since" => "2026-09-29T20:00:00-04:00", "until" => @until}) ==
               [article.guid]

      assert {:error, {:invalid_parameter, message}} =
               Bridge.bundle(%{"since" => "2026-09-30T00:00:00"})

      assert message =~ "explicit offset"

      assert {:error, {:invalid_parameter, _}} =
               Bridge.bundle(%{"since" => @until, "until" => @since})
    end

    test "a bare call is the last 24 hours, and an omitted since is 24 hours before until" do
      %{articles: [recent, old, late]} = fixture!(3)
      now = DateTime.utc_now(:second)
      extract!(recent, "Recent.", DateTime.add(now, -23, :hour))
      extract!(old, "Old.", DateTime.add(now, -25, :hour))
      extract!(late, "Late.", DateTime.add(now, 1, :minute))

      assert {:ok, bundle} = Bridge.bundle(%{})
      assert Enum.map(bundle.articles, & &1.guid) == [recent.guid]
      {:ok, since, _} = DateTime.from_iso8601(bundle.window.since)
      {:ok, until, _} = DateTime.from_iso8601(bundle.window.until)
      assert DateTime.diff(until, since, :hour) == 24
      assert DateTime.diff(DateTime.utc_now(), until, :second) in 0..5

      # The cursor keeps the resolved window, so paging does not drift with the clock.
      assert {:ok, index} = Bridge.index(%{"limit" => 1})
      assert index.totals.readable == 1

      assert {:ok, index} = Bridge.index(%{"until" => "2026-09-30T12:00:00Z"})
      assert index.window.since == "2026-09-29T12:00:00Z"
    end
  end

  describe "bundle paging" do
    test "returns every readable article exactly once and reconstructs all text at several budgets" do
      %{articles: articles} = fixture!(9)

      texts =
        articles
        |> Enum.with_index(1)
        |> Map.new(fn {article, index} ->
          text =
            case index do
              3 ->
                String.duplicate("A very long paragraph without any break at all", 400)

              5 ->
                String.duplicate("日本語のテキスト👨‍👩‍👧‍👦 mixed with accents é à ü. ", 300)

              7 ->
                Enum.map_join(
                  1..120,
                  "\n\n",
                  &("Paragraph #{&1}. " <> String.duplicate("Filler sentence. ", 12))
                )

              _ ->
                Enum.map_join(
                  1..index,
                  "\n\n",
                  &"Article #{index} paragraph #{&1}. Some ordinary text."
                )
            end

          extract!(article, text, @in_window)
          {article.guid, text}
        end)

      for budget <- [2_000, 5_000, 80_000] do
        pages = all_pages(%{"since" => @since, "until" => @until, "max_chars" => budget})

        for page <- pages do
          assert page.chars == String.length(page.text)
          assert page.chars <= budget
        end

        delivered = pages |> Enum.flat_map(& &1.articles)
        whole = for %{part: nil, guid: guid} <- delivered, do: guid
        assert whole == Enum.uniq(whole)

        split = delivered |> Enum.reject(&is_nil(&1.part)) |> Enum.group_by(& &1.guid)

        for {_guid, parts} <- split do
          assert Enum.map(parts, & &1.part) == Enum.to_list(1..length(parts))
          assert parts |> List.last() |> Map.fetch!(:parts) == length(parts)
        end

        assert Enum.sort(Enum.uniq(Enum.map(delivered, & &1.guid))) == Enum.sort(Map.keys(texts))
        assert bodies(pages) == texts
        assert List.last(pages).remaining_articles == 0
        assert List.last(pages).text =~ "[End of bundle.]"
      end
    end

    test "orders by output feed, then publication time, and lists a multi-feed article once" do
      %{articles: [first, second], source: source} = fixture!(2, feeds: ["Zebra"])

      {:ok, alpha} =
        Publishing.create_generated_feed(%{"title" => "Alpha", "input_feed_ids" => [source.id]})

      {:ok, _run} = Pipeline.backfill_output_feed(alpha.id, "test")

      # Only the later article is also in Alpha, so it sorts first.
      Repo.delete_all(
        from item in GeneratedFeedItem,
          where: item.generated_feed_id == ^alpha.id and item.article_id == ^first.id
      )

      extract!(first, "First body.", @in_window)
      extract!(second, "Second body.", @in_window)

      [page] = all_pages(%{"since" => @since, "until" => @until})
      assert Enum.map(page.articles, & &1.guid) == [second.guid, first.guid]
      assert page.text =~ "Feeds: Alpha, Zebra"
      assert page.text =~ "Feeds: Zebra"
      assert length(String.split(page.text, "===== ARTICLE #{second.guid} =====")) == 2
    end

    test "scopes by feed membership, including items held from publication" do
      %{articles: [cars_article], feeds: [cars]} = fixture!(1, feeds: ["Cars"])
      %{articles: [tech_article], feeds: [tech]} = fixture!(1, feeds: ["Tech"], source: "Ars")
      extract!(cars_article, "Cars body.", @in_window)
      extract!(tech_article, "Tech body.", @in_window)

      Repo.update_all(from(item in GeneratedFeedItem, where: item.generated_feed_id == ^cars.id),
        set: [publication_status: "processing"]
      )

      assert bundle_guids(%{"since" => @since, "until" => @until, "feeds" => "#{cars.id}"}) ==
               [cars_article.guid]

      assert bundle_guids(%{"since" => @since, "until" => @until, "feeds" => [tech.id]}) ==
               [tech_article.guid]

      assert {:error, {:invalid_parameter, message}} =
               Bridge.bundle(%{"since" => @since, "until" => @until, "feeds" => "999999"})

      assert message =~ "Unknown output feed"
    end

    test "an empty window is a successful final page" do
      assert {:ok, page} = Bridge.bundle(%{"since" => @since, "until" => @until})
      assert page.articles == []
      assert page.next_cursor == nil
      assert page.text =~ "No articles were first extracted in this window."
    end
  end

  describe "cursors" do
    setup do
      %{articles: articles} = fixture!(6)

      for article <- articles,
          do: extract!(article, String.duplicate("Sentence of filler text. ", 60), @in_window)

      :ok
    end

    test "a continuation inherits omitted parameters, including a defaulted until" do
      assert {:ok, first} = Bridge.bundle(%{"since" => @since, "max_chars" => 2_000})
      assert first.next_cursor
      resolved_until = first.window.until

      assert {:ok, second} = Bridge.bundle(%{"cursor" => first.next_cursor})
      assert second.window.until == resolved_until
      assert second.max_chars == 2_000
      # The page advanced: a later article, or the next part of the same one.
      refute second.articles == first.articles
      refute second.text == first.text

      assert {:ok, same} =
               Bridge.bundle(%{
                 "cursor" => first.next_cursor,
                 "since" => @since,
                 "until" => resolved_until,
                 "max_chars" => "2000"
               })

      assert same.text == second.text
    end

    test "conflicting explicit parameters and malformed cursors are refused" do
      assert {:ok, first} =
               Bridge.bundle(%{
                 "since" => @since,
                 "until" => "2026-10-02T00:00:00Z",
                 "max_chars" => 2_000
               })

      for conflict <- [
            %{"max_chars" => 3_000},
            %{"until" => @until},
            %{"since" => "2026-09-29T00:00:00Z"},
            %{"feeds" => "1"}
          ] do
        assert {:error, {:cursor_parameter_mismatch, message}} =
                 Bridge.bundle(Map.put(conflict, "cursor", first.next_cursor))

        assert message =~ "differs from the request this cursor was issued for"
      end

      assert {:error, {:invalid_cursor, _}} = Bridge.bundle(%{"cursor" => "not-a-cursor"})
      assert {:error, {:invalid_cursor, _}} = Bridge.index(%{"cursor" => first.next_cursor})
    end

    test "budgets outside the configured range are rejected, never clamped" do
      for bad <- [1_999, 320_001, "many"] do
        assert {:error, {:invalid_parameter, message}} =
                 Bridge.bundle(%{"since" => @since, "max_chars" => bad})

        assert message =~ "max_chars must be an integer between 2000 and 320000"
      end
    end
  end

  describe "budget too small" do
    test "fails explicitly when framing leaves no room for text and never returns a page that does not advance" do
      %{articles: [normal, long_header]} = fixture!(2)
      extract!(normal, "A short body.", @in_window)
      extract!(long_header, "Body that cannot fit beside its header.", @in_window)

      long_header
      |> Article.changeset(%{title: String.duplicate("An extremely long headline ", 120)})
      |> Repo.update!()

      set_published!(normal, ~U[2026-09-30 01:00:00Z])
      set_published!(long_header, ~U[2026-09-30 02:00:00Z])

      params = %{"since" => @since, "until" => @until, "max_chars" => 2_000}
      assert {:ok, first} = Bridge.bundle(params)
      assert Enum.map(first.articles, & &1.guid) == [normal.guid]
      assert first.next_cursor
      assert first.chars <= 2_000

      assert {:error, {:budget_too_small, message}} =
               Bridge.bundle(%{"cursor" => first.next_cursor})

      assert message =~ "larger max_chars"
      assert message =~ "cannot be reused"

      # A larger budget on a new request carries both.
      assert bundle_guids(Map.put(params, "max_chars", 8_000)) ==
               Enum.sort([normal.guid, long_header.guid])
    end
  end

  describe "index" do
    test "reports the readable and coverage sets separately with factual extraction states" do
      %{articles: [extracted, pending, failed, no_content, untouched, old]} = fixture!(6)

      for article <- [extracted, pending, failed, no_content, untouched] do
        set_first_seen!(article, @in_window)
      end

      set_first_seen!(old, ~U[2026-08-01 00:00:00Z])
      extract!(extracted, "Readable and new.", @in_window)
      extract!(old, "Old article, extracted today.", @in_window)
      set_status!(pending, "queued")
      set_status!(failed, "failed")
      set_status!(no_content, "skipped")

      assert {:ok, index} = Bridge.index(%{"since" => @since, "until" => @until})
      by_guid = Map.new(index.articles, &{&1.guid, &1})

      assert index.totals.readable == 2
      assert index.totals.first_seen == 5

      assert index.totals.first_seen_by_state == %{
               "extracted" => 1,
               "pending" => 1,
               "failed" => 1,
               "no_content" => 1,
               "not_requested" => 1
             }

      assert by_guid[extracted.guid].readable_in_window
      assert by_guid[extracted.guid].first_seen_in_window
      assert by_guid[old.guid].readable_in_window
      refute by_guid[old.guid].first_seen_in_window
      refute by_guid[pending.guid].readable_in_window
      assert by_guid[pending.guid].extraction_state == "pending"
      assert by_guid[failed.guid].extraction_state == "failed"
      assert by_guid[no_content.guid].extraction_state == "no_content"
      assert by_guid[untouched.guid].text_chars == nil
      assert index.text =~ "Readable (first extracted in the window): 2."
      assert index.text =~ "[End of index.]"

      # Reading the index starts no work.
      assert Repo.aggregate(Newspaper.Processing.PipelineStepAttempt, :count) == 0
    end

    test "pages with a bounded limit and a cursor that inherits its request" do
      %{articles: articles} = fixture!(5)
      for article <- articles, do: extract!(article, "Body.", @in_window)

      assert {:ok, first} = Bridge.index(%{"since" => @since, "until" => @until, "limit" => 2})
      assert length(first.articles) == 2
      assert first.totals.readable == 5

      assert {:ok, second} = Bridge.index(%{"cursor" => first.next_cursor})
      assert {:ok, third} = Bridge.index(%{"cursor" => second.next_cursor})
      assert third.next_cursor == nil

      guids =
        Enum.flat_map([first, second, third], fn page -> Enum.map(page.articles, & &1.guid) end)

      assert Enum.sort(guids) == Enum.sort(Enum.map(articles, & &1.guid))
      assert guids == Enum.uniq(guids)

      assert {:error, {:cursor_parameter_mismatch, _}} =
               Bridge.index(%{"cursor" => first.next_cursor, "limit" => 3})

      assert {:error, {:invalid_parameter, _}} =
               Bridge.index(%{"since" => @since, "until" => @until, "limit" => 301})
    end
  end

  describe "single article" do
    test "returns the whole text or exact slices by offset" do
      %{articles: [article, unextracted]} = fixture!(2)

      text =
        Enum.map_join(1..80, "\n\n", &("Paragraph #{&1}. " <> String.duplicate("Text. ", 30)))

      extract!(article, text, @in_window)

      assert {:ok, whole} = Bridge.article(article.guid, %{})
      assert whole.next_offset == nil
      assert whole.text =~ text

      slices =
        Stream.unfold(0, fn
          nil ->
            nil

          offset ->
            {:ok, slice} =
              Bridge.article(article.guid, %{"offset" => offset, "max_chars" => 2_000})

            assert slice.chars <= 2_000
            {slice, slice.next_offset}
        end)
        |> Enum.to_list()

      assert length(slices) > 3
      assert slices |> Enum.map(&article_body(&1.text, article.guid)) |> Enum.join() == text

      assert {:error, {:not_found, _}} = Bridge.article(unextracted.guid, %{})
      assert {:error, {:not_found, _}} = Bridge.article("art_missing", %{})

      assert {:error, {:invalid_parameter, _}} =
               Bridge.article(article.guid, %{"offset" => String.length(text) + 1})
    end
  end

  describe "feeds" do
    test "lists output feeds and sources with their last fetch facts" do
      %{source: source, feeds: [feed]} = fixture!(1, feeds: ["Cars"])
      {:ok, _source} = Intake.mark_input_feed_fetched(source, "failed")

      assert {:ok, result} = Bridge.feeds()
      assert [%{id: id, title: "Cars"}] = result.output_feeds
      assert id == feed.id
      assert [%{name: "The Autopian", last_fetch_status: "failed"}] = result.sources
      assert result.text =~ "- #{feed.id} | Cars"
      assert result.text =~ "The Autopian | enabled | failed"
    end
  end

  describe "cursor contents are untrusted (audit MCP-IMP-01, MCP-IMP-02)" do
    setup do
      %{articles: articles} = fixture!(4)

      for article <- articles,
          do: extract!(article, String.duplicate("Filler sentence here. ", 90), @in_window)

      {:ok, bundle} = Bridge.bundle(%{"since" => @since, "until" => @until, "max_chars" => 2_000})
      {:ok, index} = Bridge.index(%{"since" => @since, "until" => @until, "limit" => 2})
      %{bundle_cursor: bundle.next_cursor, index_cursor: index.next_cursor}
    end

    test "an untouched cursor still continues", ctx do
      assert {:ok, _page} = Bridge.bundle(%{"cursor" => ctx.bundle_cursor})
      assert {:ok, _page} = Bridge.index(%{"cursor" => ctx.index_cursor})
    end

    test "sizes inherited from a cursor obey the configured limits", ctx do
      for size <- [400_000, 320_001, 1_999, 0, -5] do
        cursor = tamper(ctx.bundle_cursor, &Map.put(&1, "size", size))
        assert {:error, {:invalid_cursor, message}} = Bridge.bundle(%{"cursor" => cursor})
        assert message =~ "max_chars"
      end

      for size <- [301, 0, -1] do
        cursor = tamper(ctx.index_cursor, &Map.put(&1, "size", size))
        assert {:error, {:invalid_cursor, message}} = Bridge.index(%{"cursor" => cursor})
        assert message =~ "limit"
      end
    end

    test "a cursor issued before a limit was lowered is refused", ctx do
      previous = Application.get_env(:newspaper, :bridge, [])
      on_exit(fn -> Application.put_env(:newspaper, :bridge, previous) end)

      Application.put_env(:newspaper, :bridge,
        min_chars: 500,
        max_chars: 1_500,
        max_index_limit: 1
      )

      assert {:error, {:invalid_cursor, _}} = Bridge.bundle(%{"cursor" => ctx.bundle_cursor})
      assert {:error, {:invalid_cursor, _}} = Bridge.index(%{"cursor" => ctx.index_cursor})
    end

    test "malformed fields are refused as invalid cursors and never raise", ctx do
      bundle_changes = [
        &Map.put(&1, "feeds", "not-a-list"),
        &Map.put(&1, "feeds", ["x"]),
        &Map.put(&1, "feeds", [0]),
        &Map.put(&1, "since", 42),
        &Map.put(&1, "until", "yesterday"),
        &Map.delete(&1, "since"),
        &Map.put(&1, "size", "big"),
        &Map.put(&1, "pos", "start"),
        &Map.delete(&1, "pos"),
        &Map.put(&1, "pos", %{}),
        &put_in(&1, ["pos", "t"], "noon"),
        &put_in(&1, ["pos", "a"], "one"),
        &put_in(&1, ["pos", "a"], 0),
        &put_in(&1, ["pos", "o"], -1),
        &put_in(&1, ["pos", "p"], 0),
        &put_in(&1, ["pos", "f"], "feed"),
        &Map.put(&1, "v", 99),
        &Map.put(&1, "k", "index")
      ]

      for change <- bundle_changes do
        assert {:error, {:invalid_cursor, _}} =
                 Bridge.bundle(%{"cursor" => tamper(ctx.bundle_cursor, change)})
      end

      index_changes = [
        &Map.put(&1, "pos", %{}),
        &Map.put(&1, "pos", %{"t" => "yesterday", "a" => 0}),
        &Map.put(&1, "pos", %{"t" => "2026-09-30T06:00:00Z"}),
        &Map.put(&1, "pos", %{"t" => 5, "a" => 5}),
        &Map.put(&1, "pos", %{"t" => "2026-09-30T06:00:00Z", "a" => "x"}),
        &Map.put(&1, "feeds", %{"a" => 1}),
        &Map.put(&1, "since", nil)
      ]

      for change <- index_changes do
        assert {:error, {:invalid_cursor, _}} =
                 Bridge.index(%{"cursor" => tamper(ctx.index_cursor, change)})
      end

      for junk <- [
            "%%%",
            Base.url_encode64("[1,2]", padding: false),
            Base.url_encode64("null", padding: false)
          ] do
        assert match?(
                 {:error, {code, _}} when code in [:invalid_cursor, :invalid_parameter],
                 Bridge.bundle(%{"cursor" => junk})
               )
      end
    end
  end

  describe "the budget bounds every response shape (audit MCP-IMP-03)" do
    test "an empty window whose framing cannot fit fails instead of exceeding the budget" do
      %{source: source} = fixture!(1)

      feeds =
        for number <- 1..12 do
          {:ok, feed} =
            Publishing.create_generated_feed(%{
              "title" => String.duplicate("Cars ", 40) <> "#{number}",
              "input_feed_ids" => [source.id]
            })

          feed
        end

      params = %{"since" => @since, "until" => @until, "feeds" => Enum.map(feeds, & &1.id)}

      assert {:error, {:budget_too_small, message}} =
               Bridge.bundle(Map.put(params, "max_chars", 2_000))

      assert message =~ "larger max_chars"

      assert {:ok, page} = Bridge.bundle(Map.put(params, "max_chars", 8_000))
      assert page.chars == String.length(page.text)
      assert page.chars <= 8_000
      assert page.next_cursor == nil
    end

    test "every successful page is within budget, including terminal and exhausted ones" do
      %{articles: articles} = fixture!(5)

      for article <- articles,
          do: extract!(article, String.duplicate("Some body text here. ", 100), @in_window)

      assert {:ok, first} =
               Bridge.bundle(%{"since" => @since, "until" => @until, "max_chars" => 2_000})

      assert first.next_cursor

      # Everything left is deleted or shortened between pages (live read).
      [_first | rest] = articles
      [shortened | deleted] = rest

      Repo.delete_all(
        from e in ArticleExtraction, where: e.article_id in ^Enum.map(deleted, & &1.id)
      )

      reextract!(shortened, "Now very short.", @in_window)

      pages =
        Stream.unfold(first.next_cursor, fn
          nil ->
            nil

          cursor ->
            {:ok, page} = Bridge.bundle(%{"cursor" => cursor})
            {page, page.next_cursor}
        end)
        |> Enum.to_list()

      for page <- [first | pages] do
        assert page.chars == String.length(page.text)
        assert page.chars <= 2_000
      end

      assert List.last(pages).text =~ "[End of bundle.]"
    end

    test "a filter matching no article and an empty window stay within budget" do
      %{feeds: [feed]} = fixture!(1, feeds: ["Quiet"])

      for params <- [
            %{
              "since" => @since,
              "until" => @until,
              "feeds" => "#{feed.id}",
              "max_chars" => 2_000
            },
            %{"since" => @since, "until" => @until, "max_chars" => 2_000}
          ] do
        assert {:ok, page} = Bridge.bundle(params)
        assert page.chars == String.length(page.text)
        assert page.chars <= 2_000
      end
    end
  end

  describe "fractional-second bounds keep their meaning (audit MCP-IMP-04)" do
    setup do
      %{articles: [article]} = fixture!(1)
      extract!(article, "Extracted exactly at noon.", ~U[2026-09-30 12:00:00Z])
      %{article: article}
    end

    test "since is inclusive and until exclusive at sub-second precision", %{article: article} do
      assert bundle_guids(%{"since" => "2026-09-30T12:00:00.500Z", "until" => @until}) == []

      assert bundle_guids(%{"since" => "2026-09-30T12:00:00.000Z", "until" => @until}) == [
               article.guid
             ]

      assert bundle_guids(%{"since" => @since, "until" => "2026-09-30T12:00:00.500Z"}) == [
               article.guid
             ]

      assert bundle_guids(%{"since" => @since, "until" => "2026-09-30T12:00:00Z"}) == []

      # The same instants written with another offset select the same articles.
      assert bundle_guids(%{"since" => "2026-09-30T08:00:00.500-04:00", "until" => @until}) == []

      assert bundle_guids(%{"since" => @since, "until" => "2026-09-30T08:00:00.500-04:00"}) == [
               article.guid
             ]

      assert {:ok, index} =
               Bridge.index(%{"since" => "2026-09-30T12:00:00.500Z", "until" => @until})

      assert index.totals.readable == 0
    end

    test "precision finer than a microsecond is refused rather than rounded" do
      for {name, params} <- [
            {"since", %{"since" => "2026-09-30T12:00:00.0000005Z", "until" => @until}},
            {"until", %{"since" => @since, "until" => "2026-09-30T12:00:00.0000005Z"}}
          ] do
        assert {:error, {:invalid_parameter, message}} = Bridge.bundle(params)
        assert message =~ name
        assert message =~ "microsecond"
        assert {:error, {:invalid_parameter, _}} = Bridge.index(params)
      end

      assert bundle_guids(%{"since" => "2026-09-30T12:00:00.000001Z", "until" => @until}) == []
    end

    test "cursors carry fractional bounds and distinguish them from a different instant" do
      %{articles: more} = fixture!(4, source: "Ars")

      for article <- more,
          do: extract!(article, String.duplicate("Body sentence. ", 120), @in_window)

      params = %{"since" => @since, "until" => "2026-09-30T23:59:59.250Z", "max_chars" => 2_000}
      assert {:ok, first} = Bridge.bundle(params)
      assert first.window.until == "2026-09-30T23:59:59.250Z"
      assert first.next_cursor

      assert {:ok, second} = Bridge.bundle(%{"cursor" => first.next_cursor})
      assert second.window.until == "2026-09-30T23:59:59.250Z"

      assert {:ok, _same} =
               Bridge.bundle(%{
                 "cursor" => first.next_cursor,
                 "until" => "2026-09-30T19:59:59.250-04:00"
               })

      assert {:error, {:cursor_parameter_mismatch, _}} =
               Bridge.bundle(%{
                 "cursor" => first.next_cursor,
                 "until" => "2026-09-30T23:59:59.750Z"
               })

      assert {:error, {:cursor_parameter_mismatch, _}} =
               Bridge.bundle(%{"cursor" => first.next_cursor, "until" => "2026-09-30T23:59:59Z"})
    end
  end

  describe "timestamp metadata reaches the reader (audit MCP-IMP-05)" do
    test "the index, bundle, and article texts carry first-seen and both extraction times" do
      %{articles: [article]} = fixture!(1)
      set_published!(article, ~U[2026-09-30 06:01:00Z])
      set_first_seen!(article, ~U[2026-09-30 12:00:11Z])
      extract!(article, "Body.", ~U[2026-09-30 12:00:30Z])
      reextract!(article, "Body, extracted again.", ~U[2026-09-30 12:00:42Z])

      assert {:ok, index} = Bridge.index(%{"since" => @since, "until" => @until})

      for time <- [
            "2026-09-30T06:01:00Z",
            "2026-09-30T12:00:11Z",
            "2026-09-30T12:00:30Z",
            "2026-09-30T12:00:42Z"
          ] do
        assert index.text =~ time
      end

      refute index.text =~ "Body, extracted again."

      assert {:ok, bundle} = Bridge.bundle(%{"since" => @since, "until" => @until})
      assert bundle.text =~ "First extracted: 2026-09-30T12:00:30Z"
      assert bundle.text =~ "Latest extraction: 2026-09-30T12:00:42Z"

      assert {:ok, one} = Bridge.article(article.guid, %{})
      assert one.text =~ "First extracted: 2026-09-30T12:00:30Z"
      assert one.text =~ "Latest extraction: 2026-09-30T12:00:42Z"
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp split_all("", _limit), do: []

  defp split_all(text, limit) do
    {chunk, rest} = Splitter.take(text, limit)
    [chunk | split_all(rest, limit)]
  end

  defp all_pages(params) do
    Stream.unfold(params, fn
      nil ->
        nil

      params ->
        {:ok, page} = Bridge.bundle(params)
        {page, page.next_cursor && %{"cursor" => page.next_cursor}}
    end)
    |> Enum.to_list()
  end

  defp bundle_guids(params) do
    params
    |> all_pages()
    |> Enum.flat_map(& &1.articles)
    |> Enum.map(& &1.guid)
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Rebuilds each article's text from every page it appeared on.
  defp bodies(pages) do
    pages
    |> Enum.flat_map(fn page ->
      ~r/\n===== ARTICLE (\S+) =====\n/
      |> Regex.scan(page.text, capture: :all_but_first)
      |> Enum.map(fn [guid] -> {guid, article_body(page.text, guid)} end)
    end)
    |> Enum.group_by(fn {guid, _body} -> guid end, fn {_guid, body} -> body end)
    |> Map.new(fn {guid, parts} -> {guid, Enum.join(parts)} end)
  end

  defp article_body(text, guid) do
    [_before, block] = String.split(text, "\n===== ARTICLE #{guid} =====\n", parts: 2)
    [block, _after] = String.split(block, "\n===== END #{guid} =====\n", parts: 2)
    [_header, body] = String.split(block, "\n\n", parts: 2)
    body
  end
end
