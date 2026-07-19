defmodule Newspaper.Processing.PriorityQueue do
  @priorities [:foreground, :bulk]

  def new do
    %{foreground: :queue.new(), bulk: :queue.new(), members: MapSet.new()}
  end

  def priority_for(%{batch_run_id: nil}), do: :foreground
  def priority_for(%{batch_run_id: _batch_run_id}), do: :bulk

  def put(queue, value, priority) when priority in @priorities do
    if MapSet.member?(queue.members, value) do
      queue
    else
      queue
      |> Map.update!(priority, &:queue.in(value, &1))
      |> Map.update!(:members, &MapSet.put(&1, value))
    end
  end

  def pop(queue) do
    case :queue.out(queue.foreground) do
      {{:value, value}, foreground} ->
        {{:value, value},
         %{queue | foreground: foreground, members: MapSet.delete(queue.members, value)}}

      {:empty, _foreground} ->
        case :queue.out(queue.bulk) do
          {{:value, value}, bulk} ->
            {{:value, value}, %{queue | bulk: bulk, members: MapSet.delete(queue.members, value)}}

          {:empty, _bulk} ->
            {:empty, queue}
        end
    end
  end

  def empty?(queue), do: MapSet.size(queue.members) == 0

  def to_list(queue), do: :queue.to_list(queue.foreground) ++ :queue.to_list(queue.bulk)
end
