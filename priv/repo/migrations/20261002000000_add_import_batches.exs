defmodule CATools.Repo.Migrations.AddImportBatches do
  use Ecto.Migration

  def change do
    create table(:import_batches) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :map_id, references(:maps, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "queued"
      add :total_count, :integer, null: false, default: 0
      add :processed_count, :integer, null: false, default: 0
      add :success_count, :integer, null: false, default: 0
      add :failed_count, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create index(:import_batches, [:user_id, :status])
    create index(:import_batches, [:map_id])

    create constraint(:import_batches, :valid_batch_status,
             check:
               "status in ('queued', 'processing', 'completed', 'completed_with_errors', 'cancelled')"
           )

    alter table(:map_sources) do
      add :import_batch_id, references(:import_batches, on_delete: :nilify_all)
    end

    create index(:map_sources, [:import_batch_id])
    create unique_index(:map_points, [:map_source_id], name: :map_points_source_unique_index)

    create table(:import_windows, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true
      add :scheduled_at, :utc_datetime, null: false
    end
  end
end
