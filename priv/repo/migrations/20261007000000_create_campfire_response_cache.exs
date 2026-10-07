defmodule CATools.Repo.Migrations.CreateCampfireResponseCache do
  use Ecto.Migration

  def change do
    create table(:campfire_response_cache, primary_key: false) do
      add :key, :string, primary_key: true
      add :body, :map, null: false
      add :fetched_at, :utc_datetime, null: false
    end

    create index(:campfire_response_cache, [:fetched_at])
  end
end
