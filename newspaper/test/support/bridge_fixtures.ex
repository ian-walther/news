defmodule Newspaper.BridgeFixtures do
  @moduledoc """
  Articles, extractions, and cursors for bridge tests: the same rows the
  intake and extraction pipeline would leave behind, at chosen times.
  """

  import Ecto.Query

  alias Newspaper.Content.{Article, ArticleExtraction}
  alias Newspaper.Intake
  alias Newspaper.Pipeline
  alias Newspaper.Publishing
  alias Newspaper.Repo

  @doc """
  One input source with `count` articles published a minute apart from
  2026-09-30 06:01 UTC, and an output feed per title in `:feeds`.
  """
  def fixture!(count, opts \\ []) do
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

  def extract!(article, text, at) do
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

  @doc "The same in-place update the extractor performs on a later success."
  def reextract!(article, text, at) do
    ArticleExtraction
    |> Repo.get_by!(article_id: article.id)
    |> ArticleExtraction.changeset(%{content_text: text, extracted_at: at})
    |> Repo.update!()
  end

  def set_status!(article, status) do
    Article
    |> Repo.get!(article.id)
    |> Article.changeset(%{extraction_status: status})
    |> Repo.update!()
  end

  def set_published!(article, at) do
    Article |> Repo.get!(article.id) |> Article.changeset(%{published_at: at}) |> Repo.update!()
  end

  def set_first_seen!(article, at) do
    Repo.update_all(from(a in Article, where: a.id == ^article.id), set: [inserted_at: at])
  end

  @doc "Rewrites one field of an otherwise well-formed cursor, as a client could."
  def tamper(cursor, change) do
    cursor
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> change.()
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end
end
