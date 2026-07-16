defmodule Newspaper.Content.SiteExtractionPolicy do
  use Ecto.Schema
  import Ecto.Changeset

  schema "site_extraction_policies" do
    field :site_host, :string
    field :minimum_implementation, :string, default: "extraction.simple_html"
    field :last_successful_implementation, :string
    field :last_failure_kind, :string
    field :rate_limit_delay_ms, :integer, default: 3_000
    field :backoff_until, :utc_datetime
    field :consecutive_rate_limits, :integer, default: 0
    field :last_rate_limited_at, :utc_datetime
    field :last_attempted_at, :utc_datetime
    field :escalation_enabled, :boolean, default: true
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
      :rate_limit_delay_ms,
      :backoff_until,
      :consecutive_rate_limits,
      :last_rate_limited_at,
      :last_attempted_at,
      :escalation_enabled,
      :notes
    ])
    |> validate_required([:site_host, :minimum_implementation, :rate_limit_delay_ms])
    |> validate_number(:rate_limit_delay_ms, greater_than_or_equal_to: 0)
    |> validate_number(:consecutive_rate_limits, greater_than_or_equal_to: 0)
    |> unique_constraint(:site_host)
  end
end
