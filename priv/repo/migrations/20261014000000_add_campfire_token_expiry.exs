defmodule CATools.Repo.Migrations.AddCampfireTokenExpiry do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :campfire_token_expires_at, :utc_datetime
      add :campfire_token_reminded_at, :utc_datetime
    end
  end
end
