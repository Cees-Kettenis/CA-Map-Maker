defmodule CATools.Repo.Migrations.AddMapPointClubId do
  use Ecto.Migration

  def change do
    alter table(:map_points) do
      add :club_id, :string
    end
  end
end
