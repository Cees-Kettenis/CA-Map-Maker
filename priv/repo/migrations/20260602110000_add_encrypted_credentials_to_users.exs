defmodule CATools.Repo.Migrations.AddEncryptedCredentialsToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :encrypted_credentials, :map
    end
  end
end
