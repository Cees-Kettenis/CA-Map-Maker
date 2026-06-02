defmodule CATools.Maps.UserMap do
  use Ecto.Schema
  import Ecto.Changeset

  alias CATools.Accounts.User
  alias CATools.Maps.{MapPoint, MapSource}

  @type visibility :: :private | :public

  @type t :: %__MODULE__{
          id: integer() | nil,
          user_id: integer() | nil,
          user: User.t() | Ecto.Association.NotLoaded.t(),
          name: String.t() | nil,
          description: String.t() | nil,
          visibility: visibility() | nil,
          public_slug: String.t() | nil,
          points_count: integer() | nil,
          sources_count: integer() | nil,
          last_imported_at: DateTime.t() | nil,
          source_urls_input: String.t() | nil,
          sources: [MapSource.t()] | Ecto.Association.NotLoaded.t(),
          points: [MapPoint.t()] | Ecto.Association.NotLoaded.t()
        }

  schema "maps" do
    field :name, :string
    field :description, :string
    field :visibility, Ecto.Enum, values: [:private, :public]
    field :public_slug, :string
    field :points_count, :integer, default: 0
    field :sources_count, :integer, default: 0
    field :last_imported_at, :utc_datetime
    field :source_urls_input, :string, virtual: true

    belongs_to :user, User
    has_many :sources, MapSource, foreign_key: :map_id
    has_many :points, MapPoint, foreign_key: :map_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Builds the map creation changeset.
  """
  @spec creation_changeset(t(), map()) :: Ecto.Changeset.t()
  def creation_changeset(map, attrs) do
    map
    |> cast(attrs, [:name, :description, :visibility, :source_urls_input])
    |> validate_required([:name, :visibility, :source_urls_input])
    |> validate_length(:name, max: 160)
    |> validate_length(:description, max: 2_000)
    |> unique_constraint(:public_slug)
  end
end
