defmodule Newspaper.Runtime do
  @moduledoc """
  Identity of the current VM boot. Recorded alongside pids so that ownership
  claims made in one boot are never honoured by a later one.
  """

  @key {__MODULE__, :boot_id}

  def boot_id do
    case :persistent_term.get(@key, nil) do
      nil ->
        id =
          :crypto.strong_rand_bytes(8)
          |> Base.encode16(case: :lower)
          |> then(&"#{System.system_time(:second)}-#{&1}")

        :persistent_term.put(@key, id)
        :persistent_term.get(@key)

      id ->
        id
    end
  end
end
