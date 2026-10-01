defmodule Newspaper.BridgeTest do
  use Newspaper.DataCase

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
      assert {:error, {:invalid_parameter, _}} = Bridge.bundle(%{})

      assert {:error, {:invalid_parameter, _}} =
               Bridge.bundle(%{"since" => @until, "until" => @since})
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

  defp fixture!(count, opts \\ []) do
    name = Keyword.get(opts, :source, "The Autopian")
    slug = name |> String.downcase() |> String.replace(~r/[^a-z]+/, "")

    {:ok, source} = Intake.create_input_feed(%{name: name, url: "https://#{slug}.example/feed/"})

    for index <- 1..count do
      {:ok, _raw} =
        Intake.upsert_raw_item(source, %{
          feed_guid: "#{slug}-#{index}",
          url: "https://#{slug}.example/story-#{index}/",
          title: "#{name} story #{index}",
          published_at: DateTime.add(~U[2026-09-30 06:00:00Z], index, :minute),
          discovered_at: ~U[2026-09-30 07:00:00Z]
        })
    end

    {:ok, _run} = Pipeline.process_input_feed(source.id, "test")

    feeds =
      for title <- Keyword.get(opts, :feeds, []) do
        {:ok, feed} =
          Publishing.create_generated_feed(%{"title" => title, "input_feed_ids" => [source.id]})

        {:ok, _run} = Pipeline.backfill_output_feed(feed.id, "test")
        feed
      end

    articles =
      Article
      |> where([a], like(a.canonical_url, ^"https://#{slug}.example/%"))
      |> order_by([a], asc: a.published_at)
      |> Repo.all()

    %{source: source, articles: articles, feeds: feeds}
  end

  defp extract!(article, text, at) do
    Repo.insert!(%ArticleExtraction{
      article_id: article.id,
      implementation_key: "extraction.simple_html",
      content_html: "<p>html</p>",
      content_text: text,
      extracted_at: at,
      inserted_at: at,
      updated_at: at
    })

    set_status!(article, "succeeded")
  end

  # The same in-place update the extractor performs on a later success.
  defp reextract!(article, text, at) do
    ArticleExtraction
    |> Repo.get_by!(article_id: article.id)
    |> ArticleExtraction.changeset(%{content_text: text, extracted_at: at})
    |> Repo.update!()
  end

  defp set_status!(article, status) do
    Article
    |> Repo.get!(article.id)
    |> Article.changeset(%{extraction_status: status})
    |> Repo.update!()
  end

  defp set_published!(article, at) do
    Article |> Repo.get!(article.id) |> Article.changeset(%{published_at: at}) |> Repo.update!()
  end

  defp set_first_seen!(article, at) do
    Repo.update_all(from(a in Article, where: a.id == ^article.id), set: [inserted_at: at])
  end
end
