defmodule Newspaper.DigestionTest do
  use Newspaper.DataCase, async: true

  alias Newspaper.Content.ArticleExtraction
  alias Newspaper.Digestion

  setup :verify_on_exit!

  test "discovers installed Ollama models" do
    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/tags"

      Req.Test.json(conn, %{
        "models" => [
          %{"name" => "qwen3.6:27b"},
          %{"name" => "gpt-oss:20b"}
        ]
      })
    end)

    assert {:ok, ["gpt-oss:20b", "qwen3.6:27b"]} =
             Digestion.list_models("http://desktop.home:11434/")
  end

  test "generates and validates one structured article digest" do
    summary =
      1..100
      |> Enum.chunk_every(25)
      |> Enum.map_join("\n\n", &Enum.map_join(&1, " ", fn word -> "word#{word}" end))

    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/chat"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      assert request["model"] == "qwen3.6:27b"
      assert request["stream"] == false
      assert request["format"]["required"] == ["title", "summary"]
      refute Map.has_key?(request["format"], "additionalProperties")
      refute Map.has_key?(request["format"]["properties"]["title"], "minLength")
      refute Map.has_key?(request["format"]["properties"]["summary"], "maxLength")
      assert request["options"] == %{"temperature" => 0}
      assert request["think"] == false

      Req.Test.json(conn, %{
        "model" => "qwen3.6:27b",
        "done" => true,
        "done_reason" => "stop",
        "prompt_eval_count" => 1_200,
        "eval_count" => 230,
        "message" => %{
          "role" => "assistant",
          "thinking" => "This must never be persisted.",
          "content" =>
            Jason.encode!(%{
              "title" => "A satellite rescue mission will attempt an unusually fast recovery.",
              "summary" => summary
            })
        }
      })
    end)

    extraction = %ArticleExtraction{
      id: 42,
      title: "A bold rescue mission came together fast, but will it work?",
      byline: "Stephen Clark",
      site_name: "Ars Technica",
      final_url: "https://arstechnica.com/space/example",
      content_text: String.duplicate("Detailed article content. ", 100)
    }

    settings = %{
      ollama_base_url: "http://desktop.home:11434",
      ollama_model: "qwen3.6:27b"
    }

    assert {:ok, digest, metadata} = Digestion.generate(extraction, settings)
    assert digest.title =~ "satellite rescue mission"
    assert digest.summary == summary
    assert metadata.model == "qwen3.6:27b"
    assert metadata.input_metadata["article_extraction_id"] == 42
    refute Map.has_key?(metadata.output_metadata, "message")
  end

  test "rejects undersized model output" do
    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      Req.Test.json(conn, %{
        "message" => %{
          "content" => Jason.encode!(%{"title" => "A factual title.", "summary" => "Too short."})
        }
      })
    end)

    extraction = %ArticleExtraction{content_text: "Article content."}

    assert {:error, "Generated summary is too short"} =
             Digestion.generate(extraction, %{
               ollama_base_url: "http://desktop.home:11434",
               ollama_model: "qwen3.6:27b"
             })
  end

  test "rejects summaries that do not have three to five readable paragraphs" do
    summary = Enum.map_join(1..100, " ", &"word#{&1}")

    Req.Test.stub(Newspaper.Digestion.OllamaClient, fn conn ->
      Req.Test.json(conn, %{
        "message" => %{
          "content" =>
            Jason.encode!(%{
              "title" => "A factual title describes what happened in the article.",
              "summary" => summary
            })
        }
      })
    end)

    extraction = %ArticleExtraction{content_text: "Article content."}

    assert {:error, "Generated summary must contain 3 to 5 paragraphs"} =
             Digestion.generate(extraction, %{
               ollama_base_url: "http://desktop.home:11434",
               ollama_model: "qwen3.6:27b"
             })
  end

  defp verify_on_exit!(_context) do
    Req.Test.verify_on_exit!()
    :ok
  end
end
