defmodule CATools.Campfire.ImageCacheJob do
  @moduledoc "Downloads each meetup image once, independently of event imports."
  use Oban.Worker,
    queue: :images,
    max_attempts: 1,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query
  alias CATools.{Maps, Repo}

  @impl Oban.Worker
  @doc "Stores the image locally, recording failed attempts without upstream retries."
  @spec perform(Oban.Job.t()) :: :ok
  def perform(%Oban.Job{args: %{"url" => url}}) do
    CATools.Maps.ImageCache.fetch(url, require_reference: true)

    owners =
      Repo.all(
        from p in Maps.MapPoint,
          join: m in Maps.UserMap,
          on: m.id == p.map_id,
          where: p.cover_photo_url == ^url or p.host_avatar_url == ^url,
          select: m.user_id,
          distinct: true
      )

    group_owners =
      Repo.all(
        from c in CATools.Communities.Community,
          where: c.avatar_url == ^url,
          select: c.user_id,
          distinct: true
      )

    Enum.each(Enum.uniq(owners ++ group_owners), &Maps.notify/1)
  end
end
