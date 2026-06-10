defmodule Newspaper.Guid do
  @moduledoc false

  def generate(prefix) when is_binary(prefix) do
    prefix <> "_" <> Ecto.UUID.generate()
  end

  def put_new(changeset, field, prefix) do
    case Ecto.Changeset.get_field(changeset, field) do
      nil -> Ecto.Changeset.put_change(changeset, field, generate(prefix))
      "" -> Ecto.Changeset.put_change(changeset, field, generate(prefix))
      _guid -> changeset
    end
  end
end
