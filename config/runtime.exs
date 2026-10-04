import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/ca_tools start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :ca_tools, CAToolsWeb.Endpoint, server: true
end

credentials_master_key_base64 =
  System.get_env("CREDENTIALS_MASTER_KEY_BASE64") ||
    if config_env() == :prod do
      raise "CREDENTIALS_MASTER_KEY_BASE64 is required in production"
    else
      Base.encode64(:binary.copy(<<0>>, 32))
    end

oban_import_queue_limit =
  String.to_integer(System.get_env("OBAN_IMPORT_QUEUE_LIMIT", "10"))

oban_retry_queue_limit =
  String.to_integer(System.get_env("OBAN_RETRY_QUEUE_LIMIT", "5"))

oban_maintenance_queue_limit =
  String.to_integer(System.get_env("OBAN_MAINTENANCE_QUEUE_LIMIT", "2"))

if not match?({:ok, <<_::256>>}, Base.decode64(credentials_master_key_base64)) do
  raise "CREDENTIALS_MASTER_KEY_BASE64 must be a base64-encoded 32-byte key"
end

config :ca_tools,
       :map_tile_url,
       System.get_env("MAP_TILE_URL", "https://tile.openstreetmap.org/{z}/{x}/{y}.png")

config :ca_tools, CATools.Campfire.GraphQLClient,
  endpoint:
    System.get_env(
      "CAMPFIRE_GRAPHQL_ENDPOINT",
      "https://niantic-social-api.nianticlabs.com/graphql"
    )

config :ca_tools, :runtime_secrets, credentials_master_key_base64: credentials_master_key_base64

config :ca_tools, Oban,
  repo: CATools.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(5)},
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", CATools.Campfire.MaintenanceJob},
       {"*/5 * * * *", CATools.Campfire.ImageMaintenanceJob},
       {"0 3 * * *", CATools.Campfire.ImageMaintenanceJob, args: %{"prune" => true}}
     ]}
  ],
  queues: [
    images: 1,
    imports: oban_import_queue_limit,
    retries: oban_retry_queue_limit,
    maintenance: oban_maintenance_queue_limit
  ]

config :ca_tools, CAToolsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "5000"))]

if config_env() == :prod do
  smtp_settings =
    Map.new(~w(SMTP_HOST SMTP_USERNAME SMTP_PASSWORD MAIL_FROM), fn name ->
      value = System.get_env(name)

      if is_nil(value) or String.trim(value) == "" do
        raise "#{name} is required in production"
      end

      {name, value}
    end)

  smtp_security = System.get_env("SMTP_SECURITY", "starttls")

  unless smtp_security in ~w(starttls ssl) do
    raise "SMTP_SECURITY must be starttls or ssl"
  end

  smtp_port =
    System.get_env("SMTP_PORT", if(smtp_security == "ssl", do: "465", else: "587"))
    |> String.to_integer()

  unless smtp_port in 1..65535 do
    raise "SMTP_PORT must be between 1 and 65535"
  end

  smtp_tls_options = [
    versions: [:"tlsv1.2", :"tlsv1.3"],
    verify: :verify_peer,
    cacerts: :public_key.cacerts_get(),
    server_name_indication: String.to_charlist(smtp_settings["SMTP_HOST"]),
    depth: 99,
    customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
  ]

  config :ca_tools, CATools.Mailer,
    adapter: Swoosh.Adapters.SMTP,
    relay: smtp_settings["SMTP_HOST"],
    username: smtp_settings["SMTP_USERNAME"],
    password: smtp_settings["SMTP_PASSWORD"],
    port: smtp_port,
    ssl: smtp_security == "ssl",
    tls: if(smtp_security == "ssl", do: :never, else: :always),
    auth: :always,
    no_mx_lookups: true,
    retries: 1,
    timeout: 15_000,
    tls_options: smtp_tls_options,
    sockopts: if(smtp_security == "ssl", do: smtp_tls_options, else: [])

  config :ca_tools, :mail_from, smtp_settings["MAIL_FROM"]

  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :ca_tools, CATools.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  if byte_size(secret_key_base) < 64 do
    raise "SECRET_KEY_BASE must be at least 64 bytes; generate it with mix phx.gen.secret"
  end

  host = System.get_env("PHX_HOST") || "localhost"

  config :ca_tools, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :ca_tools, CAToolsWeb.Endpoint,
    url: [
      host: host,
      port: String.to_integer(System.get_env("PUBLIC_PORT", System.get_env("PORT", "5000"))),
      scheme: System.get_env("PUBLIC_SCHEME", "http")
    ],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :ca_tools, CAToolsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :ca_tools, CAToolsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end

config :ca_tools,
       :image_storage_path,
       System.get_env("IMAGE_STORAGE_PATH") || Application.get_env(:ca_tools, :image_storage_path) ||
         Path.expand("storage/meetup_images")
