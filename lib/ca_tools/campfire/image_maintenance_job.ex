defmodule CATools.Campfire.ImageMaintenanceJob do
  @moduledoc "Expires old meetup images and converts existing originals in small batches."
  use Oban.Worker,
    queue: :images,
    max_attempts: 3,
    unique: [period: 60, states: [:available, :scheduled, :executing, :retryable]]

  @impl Oban.Worker
  @doc "Prunes expired files and processes up to twenty existing originals."
  @spec perform(Oban.Job.t()) :: :ok
  def perform(job) do
    if job.args["prune"], do: CATools.Maps.ImageCache.prune()
    CATools.Maps.ImageCache.process_existing()
    :ok
  end
end
