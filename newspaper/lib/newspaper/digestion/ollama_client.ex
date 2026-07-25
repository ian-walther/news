defmodule Newspaper.Digestion.OllamaClient do
  @moduledoc false

  @request_timeout_ms 10 * 60 * 1_000

  def list_models(base_url) when is_binary(base_url) do
    case request(:get, base_url, "/api/tags", receive_timeout: 5_000) do
      {:ok, %{status: 200, body: %{"models" => models}}} when is_list(models) ->
        models =
          models
          |> Enum.map(&model_name/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, models}

      {:ok, response} ->
        {:error, response_error(response)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  def generate_digest(base_url, model, messages, schema)
      when is_binary(base_url) and is_binary(model) do
    json = %{
      "model" => model,
      "messages" => messages,
      "stream" => false,
      "think" => false,
      "format" => schema,
      "options" => %{"temperature" => 0}
    }

    case request(:post, base_url, "/api/chat", json: json, receive_timeout: @request_timeout_ms) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        parse_digest_response(body)

      {:ok, response} ->
        {:error, response_error(response)}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp request(method, base_url, path, options) do
    options =
      [
        method: method,
        url: endpoint(base_url, path),
        retry: false
      ]
      |> Keyword.merge(options)
      |> Keyword.merge(Application.get_env(:newspaper, :ollama_req_options, []))

    Req.request(options)
  end

  defp parse_digest_response(body) do
    with content when is_binary(content) <- get_in(body, ["message", "content"]),
         {:ok, decoded} <- Jason.decode(content),
         {:ok, digest} <- validate_digest(decoded) do
      metadata =
        body
        |> Map.take([
          "model",
          "created_at",
          "done",
          "done_reason",
          "total_duration",
          "load_duration",
          "prompt_eval_count",
          "prompt_eval_duration",
          "eval_count",
          "eval_duration"
        ])
        |> Map.put("raw_content", content)

      {:ok, digest, metadata}
    else
      nil ->
        {:error, "Ollama response did not include message content"}

      {:error, %Jason.DecodeError{} = error} ->
        {:error, "Invalid structured output: #{Exception.message(error)}"}

      {:error, reason} ->
        {:error, reason}

      _value ->
        {:error, "Ollama response content was not valid JSON"}
    end
  end

  defp validate_digest(%{"title" => title, "summary" => summary})
       when is_binary(title) and is_binary(summary) do
    title = title |> String.trim() |> String.replace(~r/\s+/, " ")
    summary = normalize_summary(summary)
    summary_words = summary |> String.split(~r/\s+/, trim: true) |> length()
    summary_paragraphs = summary |> String.split(~r/\n\s*\n/, trim: true) |> length()

    cond do
      String.length(title) < 10 ->
        {:error, "Generated title is too short"}

      String.length(title) > 300 ->
        {:error, "Generated title is too long"}

      String.contains?(title, "\n") ->
        {:error, "Generated title must be one line"}

      summary_words < 80 ->
        {:error, "Generated summary is too short"}

      summary_words > 600 ->
        {:error, "Generated summary is too long"}

      summary_paragraphs not in 3..5 ->
        {:error, "Generated summary must contain 3 to 5 paragraphs"}

      true ->
        {:ok, %{title: title, summary: summary}}
    end
  end

  defp validate_digest(_output), do: {:error, "Structured output must contain title and summary"}

  defp normalize_summary(summary) do
    paragraphs =
      summary
      |> String.trim()
      |> String.split(~r/\n\s*\n/, trim: true)
      |> Enum.map(&normalize_inline_whitespace/1)

    if length(paragraphs) in 3..5 do
      Enum.join(paragraphs, "\n\n")
    else
      summary
      |> normalize_inline_whitespace()
      |> reflow_summary()
    end
  end

  defp reflow_summary(summary) do
    words = String.split(summary, ~r/\s+/, trim: true)
    paragraph_count = paragraph_count(length(words))
    sentences = String.split(summary, ~r/(?<=[.!?])\s+/u, trim: true)

    units = if length(sentences) >= paragraph_count, do: sentences, else: words

    units
    |> split_evenly(paragraph_count)
    |> Enum.map_join("\n\n", &Enum.join(&1, " "))
  end

  defp paragraph_count(word_count) when word_count < 180, do: 3
  defp paragraph_count(word_count) when word_count < 320, do: 4
  defp paragraph_count(_word_count), do: 5

  defp split_evenly(items, chunk_count) do
    item_count = length(items)
    base_size = div(item_count, chunk_count)
    extra_items = rem(item_count, chunk_count)

    0..(chunk_count - 1)
    |> Enum.map(fn index -> base_size + if(index < extra_items, do: 1, else: 0) end)
    |> Enum.map_reduce(items, fn chunk_size, remaining -> Enum.split(remaining, chunk_size) end)
    |> elem(0)
  end

  defp normalize_inline_whitespace(value),
    do: value |> String.trim() |> String.replace(~r/\s+/, " ")

  defp model_name(%{"name" => name}) when is_binary(name), do: name
  defp model_name(%{"model" => model}) when is_binary(model), do: model
  defp model_name(_model), do: nil

  defp endpoint(base_url, path) do
    base_url
    |> String.trim()
    |> String.trim_trailing("/")
    |> Kernel.<>(path)
  end

  defp response_error(%{status: status, body: %{"error" => error}}),
    do: "Ollama returned HTTP #{status}: #{error}"

  defp response_error(%{status: status}), do: "Ollama returned HTTP #{status}"
end
