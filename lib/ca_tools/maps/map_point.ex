defmodule CATools.Maps.MapPoint do
  use Ecto.Schema

  alias CATools.Maps.{MapSource, UserMap}

  @type t :: %__MODULE__{
          id: integer() | nil,
          map_id: integer() | nil,
          map_source_id: integer() | nil,
          map: UserMap.t() | Ecto.Association.NotLoaded.t(),
          source: MapSource.t() | Ecto.Association.NotLoaded.t(),
          campfire_id: String.t() | nil,
          group_name: String.t() | nil,
          title: String.t() | nil,
          description: String.t() | nil,
          latitude: float() | nil,
          longitude: float() | nil,
          address: String.t() | nil,
          starts_at: DateTime.t() | nil,
          ends_at: DateTime.t() | nil,
          source_url: String.t() | nil,
          payload_hash: String.t() | nil
        }

  schema "map_points" do
    field :campfire_id, :string
    field :group_name, :string
    field :title, :string
    field :description, :string
    field :latitude, :float
    field :longitude, :float
    field :address, :string
    field :starts_at, :utc_datetime
    field :ends_at, :utc_datetime
    field :source_url, :string
    field :payload_hash, :string

    belongs_to :map, UserMap
    belongs_to :source, MapSource, foreign_key: :map_source_id

    timestamps(type: :utc_datetime)
  end
end
