defmodule CATools.Communities.Community do
  @moduledoc "An account's monitored Campfire group and private map."
  use Ecto.Schema
  import Ecto.Changeset
  @type t :: %__MODULE__{}

  schema "communities" do
    belongs_to :user, CATools.Accounts.User
    belongs_to :map, CATools.Maps.UserMap
    field :source_url, :string
    field :club_id, :string
    field :name, :string
    field :enabled, :boolean, default: true
    field :cursor, :string
    field :last_checked_at, :utc_datetime
    field :next_check_at, :utc_datetime
    field :error_message, :string
    has_many :invitations, CATools.Communities.Invitation
    timestamps(type: :utc_datetime)
  end

  @doc "Validates the saved community link and monitoring preference."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(community, attrs) do
    changeset =
      community
      |> cast(attrs, [:source_url, :enabled])
      |> validate_required([:source_url])
      |> validate_length(:source_url, max: 4_096)

    case CATools.Campfire.ClubResolver.validate_url(get_field(changeset, :source_url)) do
      {:ok, url} -> put_change(changeset, :source_url, url)
      {:error, message} -> add_error(changeset, :source_url, message)
    end
  end
end
