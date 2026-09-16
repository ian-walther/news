defmodule Newspaper.Processing.Registry do
  @moduledoc """
  Code-owned registry of pipeline step implementations and extractor tiers.

  Step order is canonical: `@step_order` is the only ordering a feed's chain
  can have. Each step implementation declares its `scope`, `prerequisites`
  (step types that must be enabled first), and `requirements` (global
  configuration it needs). The UI renders whatever this module declares.
  """

  @site_policy_step_key "extraction.site_policy"
  @article_digest_step_key "digestion.ollama.article_digest"

  @step_order ["extraction", "digestion"]

  @extraction_order [
    "extraction.simple_html",
    "extraction.headless_browser",
    "extraction.headed_browser"
  ]

  @step_implementations %{
    @site_policy_step_key => %{
      key: @site_policy_step_key,
      step_type: "extraction",
      scope: :output,
      label: "Website-directed extraction",
      step_label: "Article extraction",
      prerequisites: [],
      requirements: [],
      default_config: %{},
      config_schema: []
    },
    @article_digest_step_key => %{
      key: @article_digest_step_key,
      step_type: "digestion",
      scope: :output,
      label: "Article digest",
      step_label: "Article digestion",
      prerequisites: ["extraction"],
      requirements: [:ollama_model],
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

  @doc "Step types in canonical execution order."
  def step_types, do: @step_order

  @doc "The canonical position of a step type in every feed's chain."
  def position_for(step_type) do
    Enum.find_index(@step_order, &(&1 == step_type)) || length(@step_order)
  end

  @doc "Sorts pipeline steps (or any maps with `step_type`) into canonical order."
  def sort_steps(steps), do: Enum.sort_by(steps, &position_for(&1.step_type))

  @doc "The registered implementation for a step type."
  def fetch_implementation_for_type(step_type) do
    case Enum.find(Map.values(@step_implementations), &(&1.step_type == step_type)) do
      nil -> :error
      implementation -> {:ok, implementation}
    end
  end

  def step_label(step_type) do
    case fetch_implementation_for_type(step_type) do
      {:ok, implementation} -> implementation.step_label
      :error -> step_type |> String.replace("_", " ") |> String.capitalize()
    end
  end

  def scope(step_type) do
    case fetch_implementation_for_type(step_type) do
      {:ok, implementation} -> implementation.scope
      :error -> :output
    end
  end

  @doc "Step types that must be enabled before `step_type` can be enabled."
  def prerequisites(step_type) do
    case fetch_implementation_for_type(step_type) do
      {:ok, implementation} -> implementation.prerequisites
      :error -> []
    end
  end

  @doc "Step types that list `step_type` as a prerequisite."
  def dependents(step_type) do
    @step_implementations
    |> Map.values()
    |> Enum.filter(&(step_type in &1.prerequisites))
    |> Enum.map(& &1.step_type)
    |> Enum.uniq()
  end

  @doc "Global configuration a step type needs before it can be enabled."
  def requirements(step_type) do
    case fetch_implementation_for_type(step_type) do
      {:ok, implementation} -> implementation.requirements
      :error -> []
    end
  end

  def step_implementations do
    @step_implementations
    |> Map.values()
    |> Enum.sort_by(&{position_for(&1.step_type), &1.label})
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
end
