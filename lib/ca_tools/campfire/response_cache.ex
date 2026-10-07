defmodule CATools.Campfire.ResponseCache do
  @moduledoc "Shares successful Campfire responses across accounts and serializes matching fetches."
  use Ecto.Schema
  import Ecto.Query
  alias CATools.Repo
  alias Ecto.Changeset

  @primary_key {:key, :string, autogenerate: false}
  schema "campfire_response_cache" do
    field :body, :map
    field :fetched_at, :utc_datetime
  end

  @doc "Returns a fresh response or fetches it once, even when multiple workers request it."
  @spec fetch(String.t(), non_neg_integer(), (-> {:ok, map()} | {:error, map()}), (map() ->
                                                                                     boolean())) ::
          {:ok, map()} | {:error, map()}
  def fetch(key, max_age, fetch, valid?) do
    cutoff = DateTime.add(DateTime.utc_now(:second), -max_age)
    fresh = from c in __MODULE__, where: c.key == ^key and c.fetched_at > ^cutoff, select: c.body

    case Repo.one(fresh) do
      nil ->
        with_lock("response:" <> key, fn ->
          # A different worker may have filled the cache while this worker waited.
          case Repo.one(fresh) do
            nil ->
              case fetch.() do
                {:ok, body} = result ->
                  if valid?.(body) do
                    %__MODULE__{key: key}
                    |> Changeset.change(body: body, fetched_at: DateTime.utc_now(:second))
                    |> Repo.insert!(
                      on_conflict: {:replace, [:body, :fetched_at]},
                      conflict_target: :key
                    )
                  end

                  result

                result ->
                  result
              end

            body ->
              {:ok, body}
          end
        end)

      body ->
        {:ok, body}
    end
  end

  @doc "Serializes work for a shared resource across processes and app instances."
  @spec with_lock(String.t(), (-> result)) :: result when result: term()
  def with_lock(key, work) do
    <<lock::signed-64, _::binary>> = :crypto.hash(:sha256, "campfire-cache:" <> key)

    Repo.checkout(
      fn ->
        Repo.query!("SELECT pg_advisory_lock($1)", [lock], timeout: 60_000)

        try do
          work.()
        after
          Repo.query!("SELECT pg_advisory_unlock($1)", [lock])
        end
      end,
      timeout: 60_000
    )
  end
end
