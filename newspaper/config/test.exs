import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :newspaper, Newspaper.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "newspaper_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :newspaper, NewspaperWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "YwCTOUbmFREYh5NOdXWrmHdvhJ4Z7T7OceM01x1X3tZ5mbh2b+ikTwGfh38/3vMv",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

config :newspaper, :processing_dispatcher_enabled, false

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
