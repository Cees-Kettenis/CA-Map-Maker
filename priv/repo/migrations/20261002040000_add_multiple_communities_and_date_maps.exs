defmodule CATools.Repo.Migrations.AddMultipleCommunitiesAndDateMaps do
  use Ecto.Migration

  def change do
    drop unique_index(:communities, [:user_id])
    create unique_index(:communities, [:user_id, :source_url])

    alter table(:maps) do
      add :meetup_date, :date
      add :utc_offset_minutes, :integer, default: 0, null: false
    end

    create table(:map_communities) do
      add :map_id, references(:maps, on_delete: :delete_all), null: false
      add :community_id, references(:communities, on_delete: :delete_all), null: false
    end

    create unique_index(:map_communities, [:map_id, :community_id])
  end
end
