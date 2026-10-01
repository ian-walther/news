defmodule NewspaperWeb.Router do
  use NewspaperWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {NewspaperWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", NewspaperWeb do
    pipe_through :browser

    live_session :admin, on_mount: NewspaperWeb.AttentionHook do
      live "/", AdminLive.Processing, :index
      live "/intake", AdminLive.Intake, :index
      live "/output-feeds", AdminLive.OutputFeeds, :index
      live "/output-feeds/:id", AdminLive.OutputFeed, :show
      live "/articles", AdminLive.Articles, :index
      live "/articles/:guid", ArticleLive.Show, :show
      live "/processing", AdminLive.Processing, :index
      live "/settings", AdminLive.Settings, :index
    end

    get "/feeds/*path", FeedController, :show
  end

  # Read API for the News MCP server (planning/mcp-news-bridge.md). No
  # authentication here: OAuth is enforced by the MCP server in front of it.
  scope "/internal/api/v1", NewspaperWeb do
    pipe_through :api

    get "/feeds", BridgeController, :feeds
    get "/articles", BridgeController, :articles
    get "/articles/:guid", BridgeController, :article
    get "/bundle", BridgeController, :bundle
  end
end
