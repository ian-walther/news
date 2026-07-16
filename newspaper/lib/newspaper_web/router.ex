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

    live "/", AdminLive.Dashboard, :index
    live "/intake", AdminLive.Intake, :index
    live "/output-feeds", AdminLive.OutputFeeds, :index
    live "/output-feeds/:id/pipeline", AdminLive.OutputFeedPipeline, :index
    live "/articles", AdminLive.Articles, :index
    live "/articles/:guid", ArticleLive.Show, :show
    live "/runs", AdminLive.Runs, :index
    live "/settings", AdminLive.Settings, :index

    get "/feeds/*path", FeedController, :show
  end

  # Other scopes may use custom stacks.
  # scope "/api", NewspaperWeb do
  #   pipe_through :api
  # end
end
