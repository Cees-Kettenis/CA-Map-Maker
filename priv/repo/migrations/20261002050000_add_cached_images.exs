defmodule CATools.Repo.Migrations.AddCachedImages do
  use Ecto.Migration

  def change do
    create table(:cached_images, primary_key: false) do
      add :id, :string, primary_key: true
      add :content_type, :string
      add :attempted_at, :utc_datetime, null: false
    end
  end
end
