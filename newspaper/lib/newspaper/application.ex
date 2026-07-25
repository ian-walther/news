defmodule Newspaper.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      NewspaperWeb.Telemetry,
      Newspaper.Repo,
      {DNSCluster, query: Application.get_env(:newspaper, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Newspaper.PubSub},
      {Task.Supervisor, name: Newspaper.Processing.TaskSupervisor},
      Newspaper.Operations.Recovery,
      Newspaper.Processing.BatchDispatcher,
      Newspaper.Processing.Dispatcher,
      Newspaper.Digestion.Dispatcher,
      Newspaper.Pipeline.Scheduler,
      # Start to serve requests, typically the last entry
      NewspaperWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Newspaper.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    NewspaperWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
