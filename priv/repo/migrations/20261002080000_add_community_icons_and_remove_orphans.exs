defmodule CATools.Repo.Migrations.AddCommunityIconsAndRemoveOrphans do
  use Ecto.Migration

  def change do
    alter table(:communities) do
      add :avatar_url, :text
    end

    execute "DELETE FROM communities WHERE map_id IS NULL", "SELECT 1"
  end
end
