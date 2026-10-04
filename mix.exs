defmodule CATools.MixProject do
  use Mix.Project

  @doc false
  @spec project() :: keyword()
  def project do
    [
      app: :ca_tools,
      version: "0.1.0",
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: dialyzer(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  @doc false
  @spec application() :: keyword()
  def application do
    [
      mod: {CATools.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  @doc false
  @spec cli() :: keyword()
  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:bcrypt_elixir, "~> 3.0"},
      {:phoenix, "~> 1.8.7"},
      # Upstream Elixir 1.20 warning fixes, pending the next Hex releases.
      {:phoenix_ecto,
       github: "phoenixframework/phoenix_ecto", ref: "d0b02063159762791982c0d44beff411b61cc5f7"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.12"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard,
       github: "phoenixframework/phoenix_live_dashboard",
       ref: "83a0bd137ed3e4c66b8037b140a2744803a48e13"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      # gen_smtp still uses Erlang's legacy catch syntax, deprecated in OTP 29.
      # Limit the compatibility option to this dependency until upstream updates it.
      {:gen_smtp, "~> 1.3",
       override: true, system_env: [{"ERL_COMPILER_OPTIONS", "[nowarn_deprecated_catch]"}]},
      {:req, "~> 0.5"},
      {:vix, "~> 0.41"},
      {:oban, "~> 2.19"},
      {:xml_builder, "~> 2.2"},
      {:hammer, "~> 7.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext,
       github: "elixir-gettext/gettext", ref: "3163e3cbf6c015d9e37efa08adf42dc3e907f58b"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3.1"},
      {:bandit, "~> 1.5"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind ca_tools", "esbuild ca_tools"],
      "assets.deploy": [
        "tailwind ca_tools --minify",
        "esbuild ca_tools --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"],
      check: ["format --check-formatted", "compile --warnings-as-errors", "test", "dialyzer"]
    ]
  end

  @spec dialyzer() :: keyword()
  defp dialyzer do
    [
      plt_add_apps: [:mix, :ex_unit],
      list_unused_filters: true
    ]
  end
end
