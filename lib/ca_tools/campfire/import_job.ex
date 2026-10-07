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
  def perform(%Oban.Job{args: %{"source_id" => source_id} = args}) do
    force = Map.get(args, "force", false)
    source = CATools.Repo.get(MapSource, source_id)

    result =
      if not force && source && source.status == :fetched && source.last_fetched_at &&
           DateTime.diff(DateTime.utc_now(), source.last_fetched_at) < 86_400 do
        {:ok, source}
      else
        Importer.import_source(source_id, force: force)
      end

    case result do
      {:ok, %MapSource{} = source} ->
        CATools.Maps.refresh_batch(source.import_batch_id)

        case CATools.Repo.get(CATools.Maps.UserMap, source.map_id) do
          nil ->
            :ok

          map ->
            case CATools.Repo.get_by(CATools.Communities.Community, map_id: map.id) do
              nil -> CATools.Maps.notify(map.user_id)
              community -> CATools.Communities.notify_group(community)
            end
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
