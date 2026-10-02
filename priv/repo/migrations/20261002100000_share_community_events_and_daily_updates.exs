defmodule CATools.Repo.Migrations.ShareCommunityEventsAndDailyUpdates do
  use Ecto.Migration

  def up do
    execute "DELETE FROM map_sources WHERE map_id IN (SELECT id FROM maps WHERE meetup_date IS NOT NULL)"

    execute "DELETE FROM import_batches WHERE map_id IN (SELECT id FROM maps WHERE meetup_date IS NOT NULL)"

    execute "UPDATE communities SET next_check_at = last_checked_at + INTERVAL '1 day' WHERE last_checked_at IS NOT NULL"
  end

  def down, do: :ok
end
