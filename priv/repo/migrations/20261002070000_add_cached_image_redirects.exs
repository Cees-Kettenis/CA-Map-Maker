defmodule CATools.Repo.Migrations.AddCachedImageRedirects do
  use Ecto.Migration

  def change do
    alter table(:cached_images) do
      add :redirect_url, :text
    end
  end
end
