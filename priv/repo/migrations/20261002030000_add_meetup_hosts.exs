defmodule CATools.Repo.Migrations.AddMeetupHosts do
  use Ecto.Migration

  def change do
    alter table(:map_points) do
      add :host_name, :text
      add :host_avatar_url, :text
    end
  end
end
