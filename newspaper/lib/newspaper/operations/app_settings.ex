defmodule Newspaper.Operations.AppSettings do
  use Ecto.Schema
  import Ecto.Changeset

  schema "app_settings" do
    field :fetch_interval_minutes, :integer, default: 5
    field :run_history_enabled, :boolean, default: true
    field :ollama_base_url, :string, default: "http://desktop.home:11434"
    field :ollama_model, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(settings, attrs) do
    settings
    |> cast(attrs, [
      :fetch_interval_minutes,
      :run_history_enabled,
      :ollama_base_url,
      :ollama_model
    ])
    |> update_change(:ollama_base_url, &String.trim/1)
    |> update_change(:ollama_model, &normalize_optional_string/1)
    |> validate_required([:fetch_interval_minutes, :run_history_enabled, :ollama_base_url])
    |> validate_number(:fetch_interval_minutes, greater_than: 0)
    |> validate_format(:ollama_base_url, ~r/^https?:\/\/[^\s]+$/,
      message: "must be an HTTP or HTTPS URL"
    )
  end

  defp normalize_optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      value -> value
    end
  end

  defp normalize_optional_string(value), do: value
end
