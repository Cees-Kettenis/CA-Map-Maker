defmodule CATools.Release do
  @moduledoc "Database operations for production releases without Mix."

  @doc "Applies pending migrations before the application starts serving requests."
  @spec migrate() :: :ok
  def migrate do
    Application.load(:ca_tools)

    Enum.each(Application.fetch_env!(:ca_tools, :ecto_repos), fn repo ->
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
        end)
    end)
  end

  @doc "Bootstraps the sole administrator using ADMIN_PASSWORD and optional ADMIN_EMAIL from trusted release tooling. Resets an existing administrator's password."
  @spec bootstrap_admin() :: :ok
  def bootstrap_admin do
    Application.load(:ca_tools)
    {:ok, _} = Application.ensure_all_started(:bcrypt_elixir)
    email = System.get_env("ADMIN_EMAIL", "cees9000@gmail.com")
    password = System.fetch_env!("ADMIN_PASSWORD")

    {:ok, {:ok, _admin}, _} =
      Ecto.Migrator.with_repo(CATools.Repo, fn _repo ->
        CATools.Accounts.bootstrap_admin(email, password)
      end)

    :ok
  end
end
