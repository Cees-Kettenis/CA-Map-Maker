defmodule CATools.Campfire.ImportJob do
  @moduledoc "Imports a queued Campfire link into a map point."

  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :args],
      keys: [:source_id],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  alias CATools.Campfire.Importer
  alias CATools.Maps.MapSource

  @impl Oban.Worker
  @doc "Imports the source and retries failed requests through Oban."
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:cancel, term()}
  def perform(%Oban.Job{args: %{"source_id" => source_id}}) do
    result = Importer.import_source(source_id)

    case result do
      {:ok, %MapSource{} = source} ->
        CATools.Maps.refresh_batch(source.import_batch_id)

        case CATools.Repo.get(CATools.Maps.UserMap, source.map_id) do
          nil -> :ok
          map -> CATools.Maps.notify(map.user_id)
        end

      _ ->
        :ok
    end

    case result do
      {:ok, %MapSource{status: :fetched}} -> :ok
      {:ok, %MapSource{status: :skipped}} -> {:cancel, :skipped}
      {:ok, %MapSource{error_code: code, error_message: message}} -> {:error, {code, message}}
      {:error, :not_found} -> {:cancel, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end
end
