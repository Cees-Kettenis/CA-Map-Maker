# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ca_tools, :scopes,
  accounts_user: [
    default: false,
    module: CATools.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: CATools.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :ca_tools, :scopes,
  user: [
    default: true,
    module: CATools.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: CATools.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

config :ca_tools,
  namespace: CATools,
  ecto_repos: [CATools.Repo],
  generators: [timestamp_type: :utc_datetime]

config :ca_tools, Oban,
  repo: CATools.Repo,
  plugins: [{Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7}],
  queues: []

config :ca_tools, CATools.Campfire.LinkResolver,
  timeout: 15_000,
  redirect_limit: 5,
  request_options: []

config :ca_tools, CATools.Campfire.GraphQLClient,
  endpoint: "https://campfire.nianticlabs.com/api/graphql",
  timeout: 20_000,
  request_options: []

# Configure the endpoint
config :ca_tools, CAToolsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CAToolsWeb.ErrorHTML, json: CAToolsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: CATools.PubSub,
  live_view: [signing_salt: "rxWqROk/"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ca_tools, CATools.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ca_tools: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  ca_tools: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :filter_parameters, [
  "authorization",
  "campfire_token_input",
  "credentials",
  "encrypted_credentials",
  "password",
  "token"
]

config :hammer,
  backend: {Hammer.Backend.ETS, [expiry_ms: 60_000 * 60 * 2, cleanup_interval_ms: 60_000 * 10]}

config :ca_tools, CATools.RateLimiter,
  limits: %{
    registration_ip: %{scale_ms: :timer.minutes(10), limit: 100},
    registration_email: %{scale_ms: :timer.hours(1), limit: 3},
    login_password_ip: %{scale_ms: :timer.minutes(15), limit: 200},
    login_password_email: %{scale_ms: :timer.minutes(15), limit: 10},
    login_magic_ip: %{scale_ms: :timer.minutes(15), limit: 100},
    login_magic_email: %{scale_ms: :timer.minutes(15), limit: 5},
    campfire_credentials_validate: %{scale_ms: :timer.minutes(10), limit: 15},
    campfire_credentials_save: %{scale_ms: :timer.minutes(10), limit: 10},
    campfire_credentials_delete: %{scale_ms: :timer.minutes(10), limit: 10}
  }

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
