defmodule CATools.Communities do
  @moduledoc "Account-owned monitored communities and invitation-only map access."
  import Ecto.Query
  alias CATools.Accounts.Scope
  alias CATools.Communities.{Community, Invitation}
  alias CATools.Campfire.CommunitySyncJob
  alias CATools.Maps.UserMap
  alias CATools.Repo
  alias Ecto.Changeset

  @doc "Returns the current account's community and invitation list."
  @spec get(Scope.t()) :: Community.t() | nil
  def get(%Scope{user: user}),
    do: Repo.get_by(Community, user_id: user.id) |> Repo.preload(:invitations)

  @doc "Builds the community settings form."
  @spec change(Scope.t(), map()) :: Changeset.t()
  def change(scope, attrs \\ %{}),
    do: Community.changeset(get(scope) || %Community{user_id: scope.user.id}, attrs)

  @doc "Saves a group, creates a private map, and queues discovery. Changing groups clears old invitations and locations."
  @spec save(Scope.t(), map()) :: {:ok, Community.t()} | {:error, term()}
  def save(scope, attrs) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])
      existing = get(scope) || %Community{user_id: scope.user.id}
      changeset = Community.changeset(existing, attrs)
      if not changeset.valid?, do: Repo.rollback(changeset)
      changed? = Changeset.get_field(changeset, :source_url) != existing.source_url

      if changed? do
        if existing.id,
          do: Repo.delete_all(from i in Invitation, where: i.community_id == ^existing.id)

        if existing.map_id, do: Repo.delete!(Repo.get!(UserMap, existing.map_id))
      end

      map_id =
        if changed? or is_nil(existing.map_id) do
          Repo.insert!(
            UserMap.changeset(%UserMap{user_id: scope.user.id}, %{
              name: "My Community",
              visibility: :private
            })
          ).id
        else
          existing.map_id
        end

      changeset = Changeset.put_change(changeset, :map_id, map_id)

      changeset =
        if changed?,
          do:
            Changeset.change(changeset,
              club_id: nil,
              name: nil,
              cursor: nil,
              last_checked_at: nil,
              error_message: nil
            ),
          else: changeset

      changeset =
        if changed? or not existing.enabled or is_nil(existing.map_id),
          do: Changeset.put_change(changeset, :next_check_at, nil),
          else: changeset

      community = Repo.insert_or_update!(changeset) |> Repo.preload(:invitations, force: true)

      if community.enabled,
        do: Oban.insert!(CommunitySyncJob.new(%{"community_id" => community.id}))

      {:ok, community}
    end)
  end

  @doc "Queues a check without allowing concurrent checks for the same community."
  @spec check_now(Scope.t()) :: :ok | {:error, atom()}
  def check_now(scope) do
    case get(scope) do
      %Community{enabled: true} = community ->
        if community.next_check_at &&
             DateTime.compare(community.next_check_at, DateTime.utc_now()) == :gt do
          {:error, :too_soon}
        else
          Oban.insert!(CommunitySyncJob.new(%{"community_id" => community.id}))
          :ok
        end

      _ ->
        {:error, :disabled}
    end
  end

  @doc "Invites an email address to view the current community while signed in."
  @spec invite(Scope.t(), map()) :: {:ok, Invitation.t()} | {:error, term()}
  def invite(scope, attrs) do
    case get(scope) do
      nil ->
        {:error, :not_found}

      community ->
        Repo.insert(Invitation.changeset(%Invitation{community_id: community.id}, attrs))
    end
  end

  @doc "Revokes an invitation owned by this account."
  @spec revoke(Scope.t(), term()) :: :ok
  def revoke(scope, invitation_id) do
    with %Community{} = community <- get(scope),
         {:ok, id} <- Ecto.Type.cast(:id, invitation_id) do
      Repo.delete_all(
        from i in Invitation, where: i.community_id == ^community.id and i.id == ^id
      )
    end

    :ok
  end

  @doc "Returns a community map only to its owner or an explicitly invited, confirmed account."
  @spec shared_map(Scope.t() | nil, term()) :: UserMap.t() | nil
  def shared_map(scope, id) do
    case {scope, Ecto.Type.cast(:id, id)} do
      {%Scope{user: %{confirmed_at: confirmed} = user}, {:ok, map_id}}
      when not is_nil(confirmed) ->
        email = String.downcase(user.email)

        Repo.one(
          from m in UserMap,
            join: c in Community,
            on: c.map_id == m.id,
            left_join: i in Invitation,
            on: i.community_id == c.id and i.email == ^email,
            where: m.id == ^map_id and (c.user_id == ^user.id or not is_nil(i.id)),
            distinct: true,
            preload: [:points]
        )

      _ ->
        nil
    end
  end
end
