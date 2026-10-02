defmodule CATools.Communities.Invitation do
  @moduledoc "An email address allowed to view a private community map."
  use Ecto.Schema
  import Ecto.Changeset
  @type t :: %__MODULE__{}

  schema "community_invitations" do
    belongs_to :community, CATools.Communities.Community
    field :email, :string
    timestamps(type: :utc_datetime)
  end

  @doc "Validates and normalizes an invited account email."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(invitation, attrs) do
    invitation
    |> cast(attrs, [:email])
    |> update_change(:email, &String.downcase(String.trim(&1)))
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s@]+@[^\s@]+$/)
    |> validate_length(:email, max: 160)
    |> unique_constraint([:community_id, :email])
  end
end
