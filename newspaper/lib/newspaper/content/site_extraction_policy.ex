defmodule Newspaper.Content.SiteExtractionPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "site_extraction_policies" do
    field :site_host, :string
    field :minimum_implementation, :string, default: "extraction.simple_html"
    field :last_successful_implementation, :string
    field :last_failure_kind, :string
    field :minimum_request_interval_ms, :integer, default: 3_000
    field :backoff_until, :utc_datetime
    field :consecutive_rate_limits, :integer, default: 0
    field :last_rate_limited_at, :utc_datetime
    field :last_attempted_at, :utc_datetime
    field :escalation_enabled, :boolean, default: true
    field :timeout_ms, :integer, default: 20_000
    field :minimum_text_length, :integer, default: 500
    field :notes, :string

    has_many :article_extraction_attempts, Newspaper.Content.ArticleExtractionAttempt

    timestamps(type: :utc_datetime)
  end

  def changeset(policy, attrs) do
    policy
    |> cast(attrs, [
      :site_host,
      :minimum_implementation,
      :last_successful_implementation,
      :last_failure_kind,
      :minimum_request_interval_ms,
      :backoff_until,
      :consecutive_rate_limits,
      :last_rate_limited_at,
      :last_attempted_at,
      :escalation_enabled,
      :timeout_ms,
      :minimum_text_length,
      :notes
    ])
    |> validate_required([
      :site_host,
      :minimum_implementation,
      :minimum_request_interval_ms,
      :timeout_ms,
      :minimum_text_length
    ])
    |> validate_number(:minimum_request_interval_ms, greater_than_or_equal_to: 0)
    |> validate_number(:consecutive_rate_limits, greater_than_or_equal_to: 0)
    |> validate_number(:timeout_ms,
      greater_than_or_equal_to: 1_000,
      less_than_or_equal_to: 120_000
    )
    |> validate_number(:minimum_text_length,
      greater_than_or_equal_to: 100,
      less_than_or_equal_to: 100_000
    )
    |> unique_constraint(:site_host)
  end
end
