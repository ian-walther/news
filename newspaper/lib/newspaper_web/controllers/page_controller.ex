defmodule NewspaperWeb.PageController do
  use NewspaperWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
