defmodule CATools.Repo.Migrations.AddImageDownloadStatus do
  use Ecto.Migration

  def change do
    alter table(:cached_images) do
      add :status, :string, null: false, default: "downloading"
      add :error_code, :string
      add :error_message, :text
      add :http_status, :integer
      add :bytes, :integer
    end

    execute "UPDATE cached_images SET status = CASE WHEN content_type IS NOT NULL THEN 'saved' ELSE 'failed' END, error_message = CASE WHEN content_type IS NULL THEN 'Previous download failed without recording a reason.' ELSE NULL END",
            "SELECT 1"
  end
end
