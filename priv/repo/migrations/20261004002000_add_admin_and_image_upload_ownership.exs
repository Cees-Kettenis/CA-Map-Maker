defmodule CATools.Repo.Migrations.AddAdminAndImageUploadOwnership do
  use Ecto.Migration

  def up do
    alter table(:users) do
      add :admin, :boolean, null: false, default: false
    end

    execute "UPDATE users SET admin = true WHERE lower(email) = 'cees9000@gmail.com'"
    execute "UPDATE users SET encrypted_credentials = NULL WHERE NOT admin"
    create unique_index(:users, [:admin], where: "admin", name: :users_single_admin_index)

    create table(:image_uploads, primary_key: false) do
      add :user_id, references(:users, on_delete: :delete_all), primary_key: true

      add :image_id, references(:cached_images, type: :string, on_delete: :delete_all),
        primary_key: true
    end

    create index(:image_uploads, [:image_id])

    execute "INSERT INTO image_uploads (user_id, image_id) SELECT DISTINCT user_id, image_id FROM maps WHERE image_id IS NOT NULL AND image_id IN (SELECT id FROM cached_images)"
  end

  def down do
    drop table(:image_uploads)
    drop index(:users, [:admin], name: :users_single_admin_index)

    alter table(:users) do
      remove :admin
    end
  end
end
