defmodule CATools.Repo.Migrations.AddMeetupCoverPhotos do
  use Ecto.Migration

  def change do
    alter table(:map_points) do
      add :cover_photo_url, :text
    end
  end
end
