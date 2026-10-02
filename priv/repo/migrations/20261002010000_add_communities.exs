defmodule CATools.Repo.Migrations.AddCommunities do
  use Ecto.Migration

  def change do
    create table(:communities) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :map_id, references(:maps, on_delete: :nilify_all)
      add :source_url, :text, null: false
      add :club_id, :text
      add :name, :text
      add :enabled, :boolean, null: false, default: true
      add :cursor, :text
      add :last_checked_at, :utc_datetime
      add :next_check_at, :utc_datetime
      add :error_message, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:communities, [:user_id])
    create unique_index(:communities, [:map_id])

    create table(:community_invitations) do
      add :community_id, references(:communities, on_delete: :delete_all), null: false
      add :email, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:community_invitations, [:community_id, :email])
  end
end
