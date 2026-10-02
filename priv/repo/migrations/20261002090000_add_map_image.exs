defmodule CATools.Repo.Migrations.AddMapImage do
  use Ecto.Migration

  def change do
    alter table(:maps) do
      add :image_id, :string
    end
  end
end
