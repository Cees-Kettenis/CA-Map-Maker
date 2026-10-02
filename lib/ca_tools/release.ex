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
end
