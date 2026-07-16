defmodule Newspaper.Processing.Registry do
  @extraction_order [
    "extraction.simple_html",
    "extraction.headless_browser",
    "extraction.headed_browser"
  ]

  @implementations %{
    "extraction.simple_html" => %{
      key: "extraction.simple_html",
      step_type: "extraction",
      label: "Simple HTML extraction",
      runtime: Newspaper.Extraction.SimpleHtmlWorker,
      default_config: %{
        "timeout_ms" => 20_000,
        "minimum_text_length" => 500
      },
      config_schema: [
        %{
          key: "timeout_ms",
          type: :integer,
          minimum: 1_000,
          maximum: 120_000
        },
        %{
          key: "minimum_text_length",
          type: :integer,
          minimum: 100,
          maximum: 100_000
        }
      ]
    }
  }

  def all do
    @implementations
    |> Map.values()
    |> Enum.sort_by(& &1.label)
  end

  def fetch(key), do: Map.fetch(@implementations, key)
  def fetch!(key), do: Map.fetch!(@implementations, key)
  def keys, do: Map.keys(@implementations)

  def extraction_candidates(configured_key, minimum_key) do
    start_index = max(extraction_index(configured_key), extraction_index(minimum_key))

    @extraction_order
    |> Enum.drop(start_index)
    |> Enum.filter(&Map.has_key?(@implementations, &1))
  end

  def harder_than?(candidate, current) do
    extraction_index(candidate) > extraction_index(current)
  end

  def normalize_config(key, attrs) do
    with {:ok, implementation} <- fetch(key) do
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
