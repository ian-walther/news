defmodule Newspaper.Repo do
  use Ecto.Repo,
    otp_app: :newspaper,
    adapter: Ecto.Adapters.Postgres
end
