defmodule CATools.Repo.Migrations.AddImageProcessingVersion do
  use Ecto.Migration

  def change do
    alter table(:cached_images) do
      add :processing_version, :integer
    end
  end
end
