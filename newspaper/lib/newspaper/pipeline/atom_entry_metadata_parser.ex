defmodule Newspaper.Pipeline.AtomEntryMetadataParser do
  @moduledoc false

  def parse(document) when is_binary(document) do
    initial_state = %{entries: %{}, current_id: nil, current_categories: []}

    case Fiet.StackParser.parse(document, initial_state, __MODULE__) do
      {:ok, %{entries: entries}} -> entries
      {:error, _reason} -> %{}
    end
  end

  @doc false
  def handle_event(:start_element, {"entry", _, _}, _stack, state) do
    %{state | current_id: nil, current_categories: []}
  end

  def handle_event(
        :end_element,
        {"id", _, content},
        [{"entry", _, _} | _],
        state
      ) do
    %{state | current_id: content}
  end

  def handle_event(
        :end_element,
        {"category", attributes, _content},
        [{"entry", _, _} | _],
        state
      ) do
    category = %{
      "term" => attribute(attributes, "term"),
      "scheme" => attribute(attributes, "scheme"),
      "label" => attribute(attributes, "label")
    }

    %{state | current_categories: [category | state.current_categories]}
  end

  def handle_event(:end_element, {"entry", _, _}, _stack, state) do
    entries =
      if present?(state.current_id) do
        Map.put(state.entries, state.current_id, Enum.reverse(state.current_categories))
      else
        state.entries
      end

    %{state | entries: entries, current_id: nil, current_categories: []}
  end

  def handle_event(_event_type, _element, _stack, state), do: state

  defp attribute(attributes, name) do
    Enum.find_value(attributes, fn
      {^name, value} -> value
      _attribute -> nil
    end)
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
