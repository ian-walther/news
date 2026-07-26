defmodule Newspaper.Processing.Registry do
  @site_policy_step_key "extraction.site_policy"
  @article_digest_step_key "digestion.ollama.article_digest"

  @extraction_order [
    "extraction.simple_html",
    "extraction.headless_browser",
    "extraction.headed_browser"
  ]

  @step_implementations %{
    @site_policy_step_key => %{
      key: @site_policy_step_key,
      step_type: "extraction",
      label: "Website-directed extraction",
      default_config: %{},
      config_schema: []
    },
    @article_digest_step_key => %{
      key: @article_digest_step_key,
      step_type: "digestion",
      label: "Article digest",
      default_config: %{},
      config_schema: []
    }
  }

  @extractors %{
    "extraction.simple_html" => %{
      key: "extraction.simple_html",
      step_type: "extraction",
      label: "Simple HTML extraction",
      runtime: Newspaper.Extraction.SimpleHtmlWorker
    },
    "extraction.headless_browser" => %{
      key: "extraction.headless_browser",
      step_type: "extraction",
      label: "Headless browser extraction",
      runtime: Newspaper.Extraction.HeadlessBrowserWorker
    },
    "extraction.headed_browser" => %{
      key: "extraction.headed_browser",
      step_type: "extraction",
      label: "Authenticated headed browser",
      runtime: Newspaper.Extraction.HeadedBrowserWorker
    }
  }

  def fetch_step(key), do: Map.fetch(@step_implementations, key)

  def site_policy_step_key, do: @site_policy_step_key
  def article_digest_step_key, do: @article_digest_step_key

  def step_implementations do
    @step_implementations
    |> Map.values()
    |> Enum.sort_by(&{step_type_index(&1.step_type), &1.label})
  end

  def extractors do
    @extractors
    |> Map.values()
    |> Enum.sort_by(&extraction_index(&1.key))
  end

  def fetch_extractor(key), do: Map.fetch(@extractors, key)
  def fetch_extractor!(key), do: Map.fetch!(@extractors, key)

  def extraction_candidates(minimum_key) do
    @extraction_order
    |> Enum.drop(extraction_index(minimum_key))
    |> Enum.filter(&Map.has_key?(@extractors, &1))
  end

  def harder_extractor_than?(candidate, current) do
    extraction_index(candidate) > extraction_index(current)
  end

  def normalize_step_config(key, attrs) do
    with {:ok, implementation} <- fetch_step(key) do
      Enum.reduce_while(
        implementation.config_schema,
        {:ok, implementation.default_config},
        fn field, {:ok, config} ->
          case normalize_field(attrs, field) do
            {:ok, value} -> {:cont, {:ok, Map.put(config, field.key, value)}}
            {:error, _reason} = error -> {:halt, error}
          end
        end
      )
    end
  end

  defp normalize_field(attrs, %{type: :integer} = field) do
    value = Map.get(attrs, field.key) || Map.get(attrs, String.to_existing_atom(field.key))

    case parse_integer(value) do
      integer
      when is_integer(integer) and integer >= field.minimum and integer <= field.maximum ->
        {:ok, integer}

      _ ->
        {:error, {field.key, "must be between #{field.minimum} and #{field.maximum}"}}
    end
  end

  defp parse_integer(value) when is_integer(value), do: value

  defp parse_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> nil
    end
  end

  defp parse_integer(_value), do: nil

  defp extraction_index(key) do
    Enum.find_index(@extraction_order, &(&1 == key)) || 0
  end

  defp step_type_index("extraction"), do: 0
  defp step_type_index("digestion"), do: 1
  defp step_type_index(_step_type), do: 99
end
