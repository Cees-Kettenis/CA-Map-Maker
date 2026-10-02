defmodule CATools.Communities do
  @moduledoc "Account-owned monitored communities and invitation-only map access."
  import Ecto.Query
  alias CATools.Accounts.Scope
  alias CATools.Communities.{Community, Invitation}
  alias CATools.Campfire.CommunitySyncJob
  alias CATools.Maps.UserMap
  alias CATools.Repo
  alias Ecto.Changeset

  @doc "Lists this account's tracked communities in the order they were added."
  @spec list(Scope.t()) :: [Community.t()]
  def list(scope) do
    Repo.all(
      from c in Community,
        where: c.user_id == ^scope.user.id and not is_nil(c.map_id),
        order_by: c.id,
        preload: [:invitations]
    )
  end

  @doc "Gets an owned community, or the first community when no ID is supplied."
  @spec get(Scope.t(), term()) :: Community.t() | nil
  def get(scope, id \\ nil) do
    case id do
      nil ->
        List.first(list(scope))

      :new ->
        nil

      value ->
        case Ecto.Type.cast(:id, value) do
          {:ok, id} when is_integer(id) and id > 0 ->
            Repo.one(
              from c in Community,
                where: c.user_id == ^scope.user.id and c.id == ^id and not is_nil(c.map_id),
                preload: [:invitations]
            )

          _ ->
            nil
        end
    end
  end

  @doc "Builds an owned community settings form."
  @spec change(Scope.t(), map(), term()) :: Changeset.t()
  def change(scope, attrs \\ %{}, id \\ nil),
    do: Community.changeset(get(scope, id) || %Community{user_id: scope.user.id}, attrs)

  @doc "Adds a list of group links atomically, leaving existing communities and invitations intact."
  @spec add_links(Scope.t(), term()) :: {:ok, [Community.t()]} | {:error, term()}
  def add_links(scope, input) do
    links =
      if is_binary(input),
        do:
          String.split(input, ~r/\r\n|\n|\r/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq(),
        else: []

    cond do
      links == [] ->
        {:error, "Paste at least one group link."}

      length(links) > 100 ->
        {:error, "Add up to 100 groups at a time."}

      true ->
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])

          communities =
            Enum.map(links, fn link ->
              existing = Repo.get_by(Community, user_id: scope.user.id, source_url: link)

              if existing do
                Repo.preload(existing, :invitations)
              else
                case save(scope, %{source_url: link}, :new) do
                  {:ok, community} -> community
                  {:error, reason} -> Repo.rollback(reason)
                end
              end
            end)

          {:ok, communities}
        end)
    end
    |> then(fn result ->
      if match?({:ok, _}, result), do: CATools.Maps.notify(scope.user.id)
      result
    end)
  end

  @doc "Saves a group, creates a private map, and queues discovery. Changing groups clears old invitations and locations."
  @spec save(Scope.t(), map(), term()) :: {:ok, Community.t()} | {:error, term()}
  def save(scope, attrs, id \\ nil) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])
      if id not in [nil, :new] and is_nil(get(scope, id)), do: Repo.rollback(:not_found)
      existing = get(scope, id) || %Community{user_id: scope.user.id}
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
              avatar_url: nil,
              cursor: nil,
              last_checked_at: nil,
              error_message: nil
            ),
          else: changeset

      changeset =
        if changed? or not existing.enabled or is_nil(existing.map_id),
          do: Changeset.put_change(changeset, :next_check_at, nil),
          else: changeset

      community =
        case Repo.insert_or_update(changeset) do
          {:ok, community} -> Repo.preload(community, :invitations, force: true)
          {:error, changeset} -> Repo.rollback(changeset)
        end

      if community.enabled,
        do: Oban.insert!(CommunitySyncJob.new(%{"community_id" => community.id}))

      {:ok, community}
    end)
    |> then(fn result ->
      if match?({:ok, _}, result), do: CATools.Maps.notify(scope.user.id)
      result
    end)
  end

  @doc "Deletes an owned community and its map, invitations and linked-map selections."
  @spec delete(Scope.t(), term()) :: {:ok, UserMap.t()} | {:error, term()}
  def delete(scope, id) do
    with {:ok, id} when is_integer(id) and id > 0 <- Ecto.Type.cast(:id, id),
         %Community{} = community <- get(scope, id) do
      CATools.Maps.delete_map(scope, community.map_id)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "Queues a check without allowing concurrent checks for the same community."
  @spec check_now(Scope.t(), term()) :: :ok | {:error, atom()}
  def check_now(scope, id \\ nil) do
    case get(scope, id) do
      %Community{enabled: true} = community ->
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [scope.user.id])

          busy =
            Repo.exists?(
              from j in Oban.Job,
                where:
                  j.worker == "CATools.Campfire.CommunitySyncJob" and j.state == "executing" and
                    fragment("(?->>'community_id')::bigint", j.args) == ^community.id
            )

          unless busy do
            Repo.update!(Changeset.change(community, next_check_at: nil, cursor: nil))

            Oban.insert!(
              CommunitySyncJob.new(%{"community_id" => community.id, "force" => true},
                replace: [:args, :scheduled_at]
              )
            )
          end

          {:ok, :queued}
        end)

        CATools.Maps.notify(scope.user.id)
        :ok

      _ ->
        {:error, :disabled}
    end
  end

  @doc "Invites an email address to view the current community while signed in."
  @spec invite(Scope.t(), map(), term()) :: {:ok, Invitation.t()} | {:error, term()}
  def invite(scope, attrs, id \\ nil) do
    case get(scope, id) do
      nil ->
        {:error, :not_found}

      community ->
        Repo.insert(Invitation.changeset(%Invitation{community_id: community.id}, attrs))
    end
    |> then(fn result ->
      if match?({:ok, _}, result), do: CATools.Maps.notify(scope.user.id)
      result
    end)
  end

  @doc "Revokes an invitation owned by this account."
  @spec revoke(Scope.t(), term()) :: :ok
  def revoke(scope, invitation_id) do
    with {:ok, id} <- Ecto.Type.cast(:id, invitation_id) do
      Repo.delete_all(
        from i in Invitation,
          join: c in Community,
          on: c.id == i.community_id,
          where: c.user_id == ^scope.user.id and i.id == ^id
      )
    end

    CATools.Maps.notify(scope.user.id)
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
            preload: [:points, :community]
        )

      _ ->
        nil
    end
  end
end
