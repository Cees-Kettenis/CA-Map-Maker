defmodule CATools.Maps.MapSource do
  use Ecto.Schema

  alias CATools.Maps.{MapPoint, UserMap}

  @type status :: :pending | :processing | :fetched | :failed | :skipped

  @type t :: %__MODULE__{
          id: integer() | nil,
          map_id: integer() | nil,
          map: UserMap.t() | Ecto.Association.NotLoaded.t(),
          original_url: String.t() | nil,
          resolved_url: String.t() | nil,
          campfire_id: String.t() | nil,
          status: status() | nil,
          error_code: String.t() | nil,
          error_message: String.t() | nil,
          attempts: integer() | nil,
          last_fetched_at: DateTime.t() | nil,
          next_fetch_at: DateTime.t() | nil,
          point: MapPoint.t() | Ecto.Association.NotLoaded.t()
        }

  schema "map_sources" do
    field :original_url, :string
    field :resolved_url, :string
    field :campfire_id, :string
    field :status, Ecto.Enum, values: [:pending, :processing, :fetched, :failed, :skipped]
    field :error_code, :string
    field :error_message, :string
    field :attempts, :integer, default: 0
    field :last_fetched_at, :utc_datetime
    field :next_fetch_at, :utc_datetime

    belongs_to :map, UserMap
    has_one :point, MapPoint

    timestamps(type: :utc_datetime)
  end
end
