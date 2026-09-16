defmodule NewspaperWeb.AdminLive.IntakeSitesTest do
  use NewspaperWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Newspaper.Content
  alias Newspaper.Content.SiteExtractionPolicy
  alias Newspaper.Repo

  test "creates, edits, and removes website extraction policy from Sources", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/intake")

    assert has_element?(view, "#app-nav [data-nav='intake'][aria-current='page']", "Sources")
    assert has_element?(view, "#website-policies")
    assert has_element?(view, "#new-site-policy-form option[value='extraction.headless_browser']")
    assert has_element?(view, "#new-site-policy-form option[value='extraction.headed_browser']")

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
    assert has_element?(view, "#site-policy-#{policy.id}")
    refute has_element?(view, "#retry-site-now-#{policy.id}")

    view |> element("#edit-site-policy-#{policy.id}") |> render_click()

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
    assert policy.timeout_ms == 60_000

    view |> element("#delete-site-policy-#{policy.id}") |> render_click()
    refute Repo.get(SiteExtractionPolicy, policy.id)
  end

  test "shows the latest global fetch and offers Fetch all now", %{conn: conn} do
    {:ok, run} = Newspaper.Operations.start_run("fetch_all", "scheduled")

    {:ok, _run} =
      Newspaper.Operations.finish_run(run, "succeeded", %{
        summary_counts: %{"ok" => 2, "error" => 0}
      })

    {:ok, view, _html} = live(conn, ~p"/intake")

    assert has_element?(view, "#latest-feed-refresh", "2 feeds succeeded")
    assert has_element?(view, "#fetch-all-now", "Fetch all now")
  end
end
