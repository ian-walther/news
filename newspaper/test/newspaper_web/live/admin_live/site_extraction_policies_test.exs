defmodule NewspaperWeb.AdminLive.SiteExtractionPoliciesTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Repo

  test "creates, edits, and removes website extraction policy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sites")

    assert has_element?(view, "#new-site-policy-form")

    assert has_element?(
             view,
             "#new-site-policy-form option[value='extraction.headless_browser']"
           )

    assert has_element?(
             view,
             "#new-site-policy-form option[value='extraction.headed_browser']"
           )

    view
    |> form("#new-site-policy-form",
      site_extraction_policy: %{
        "site_host" => "WWW.ArsTechnica.com",
        "minimum_implementation" => "extraction.simple_html",
        "escalation_enabled" => "false",
        "minimum_request_interval_ms" => "12000",
        "timeout_ms" => "45000",
        "minimum_text_length" => "750",
        "notes" => "Static HTML works reliably"
      }
    )
    |> render_submit()

    policy = Repo.one!(SiteExtractionPolicy)
    assert policy.site_host == "arstechnica.com"
    refute policy.escalation_enabled
    assert policy.minimum_request_interval_ms == 12_000
    assert policy.timeout_ms == 45_000
    assert policy.minimum_text_length == 750
    assert has_element?(view, "#site-policy-#{policy.id}")

    view
    |> element("#edit-site-policy-#{policy.id}")
    |> render_click()

    view
    |> form("#edit-site-policy-form-#{policy.id}",
      site_extraction_policy: %{
        "site_host" => "arstechnica.com",
        "minimum_implementation" => "extraction.simple_html",
        "escalation_enabled" => "true",
        "minimum_request_interval_ms" => "3000",
        "timeout_ms" => "60000",
        "minimum_text_length" => "1000",
        "notes" => ""
      }
    )
    |> render_submit()

    policy = Content.get_site_extraction_policy!(policy.id)
    assert policy.escalation_enabled
    assert policy.minimum_request_interval_ms == 3_000
    assert policy.timeout_ms == 60_000
    assert policy.minimum_text_length == 1_000

    view
    |> element("#delete-site-policy-#{policy.id}")
    |> render_click()

    refute Repo.get(SiteExtractionPolicy, policy.id)
  end

  test "offers an immediate retry for a site in backoff", %{conn: conn} do
    {:ok, policy} =
      Content.create_site_extraction_policy(%{
        site_host: "racer.com",
        consecutive_rate_limits: 3,
        backoff_until: DateTime.add(DateTime.utc_now(:second), 15 * 60, :second)
      })

    {:ok, view, _html} = live(conn, ~p"/sites")

    assert has_element?(view, "#retry-site-now-#{policy.id}", "Try now")

    view
    |> element("#retry-site-now-#{policy.id}")
    |> render_click()

    assert has_element?(view, "#flash-info", "No queued articles for racer.com")
  end
end
