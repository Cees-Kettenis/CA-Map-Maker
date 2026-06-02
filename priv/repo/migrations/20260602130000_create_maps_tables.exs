defmodule CATools.Repo.Migrations.CreateMapsTables do
  use Ecto.Migration

  def change do
    create table(:maps) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :visibility, :string, null: false
      add :public_slug, :string
      add :points_count, :integer, null: false, default: 0
      add :sources_count, :integer, null: false, default: 0
      add :last_imported_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:maps, [:user_id])
    create index(:maps, [:user_id, :inserted_at])
    create unique_index(:maps, [:public_slug])

    create constraint(:maps, :maps_visibility_must_be_valid,
             check: "visibility in ('private', 'public')"
           )

    create table(:map_sources) do
      add :map_id, references(:maps, on_delete: :delete_all), null: false
      add :original_url, :text, null: false
      add :resolved_url, :text
      add :campfire_id, :string
      add :status, :string, null: false, default: "pending"
      add :error_code, :string
      add :error_message, :text
      add :attempts, :integer, null: false, default: 0
      add :last_fetched_at, :utc_datetime
      add :next_fetch_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:map_sources, [:map_id])
    create index(:map_sources, [:status])
    create index(:map_sources, [:next_fetch_at])
    create unique_index(:map_sources, [:map_id, :original_url])

    create unique_index(:map_sources, [:map_id, :campfire_id], where: "campfire_id is not null")

    create constraint(:map_sources, :map_sources_status_must_be_valid,
             check: "status in ('pending', 'processing', 'fetched', 'failed', 'skipped')"
           )

    create table(:map_points) do
      add :map_id, references(:maps, on_delete: :delete_all), null: false
      add :map_source_id, references(:map_sources, on_delete: :delete_all), null: false
      add :campfire_id, :string
      add :group_name, :string
      add :title, :string
      add :description, :text
      add :latitude, :float
      add :longitude, :float
      add :address, :text
      add :starts_at, :utc_datetime
      add :ends_at, :utc_datetime
      add :source_url, :text
      add :payload_hash, :string

      timestamps(type: :utc_datetime)
    end

    create index(:map_points, [:map_id])
    create index(:map_points, [:map_source_id])
    create index(:map_points, [:campfire_id])
    create index(:map_points, [:latitude, :longitude])
  end
end
