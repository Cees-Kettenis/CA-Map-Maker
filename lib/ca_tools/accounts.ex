defmodule CATools.Accounts do
  @moduledoc """
  The Accounts context.
  """

  import Ecto.Query, warn: false
  alias CATools.Repo

  alias CATools.Accounts.{CampfireCredentials, User, UserNotifier, UserToken}
  alias Ecto.Changeset

  @type session_lookup_result :: {User.t(), DateTime.t()} | nil
  @type token_disconnect_result :: {:ok, {User.t(), [UserToken.t()]}} | {:error, term()}

  ## Database getters

  @doc """
  Gets a user by email.

  ## Examples

      iex> get_user_by_email("foo@example.com")
      %User{}

      iex> get_user_by_email("unknown@example.com")
      nil

  """
  @spec get_user_by_email(term()) :: User.t() | nil
  def get_user_by_email(email) do
    case email do
      value when is_binary(value) ->
        Repo.get_by(User, email: value)

      _ ->
        nil
    end
  end

  @doc """
  Gets a user by email and password.

  ## Examples

      iex> get_user_by_email_and_password("foo@example.com", "correct_password")
      %User{}

      iex> get_user_by_email_and_password("foo@example.com", "invalid_password")
      nil

  """
  @spec get_user_by_email_and_password(term(), term()) :: User.t() | nil
  def get_user_by_email_and_password(email, password) do
    case {email, password} do
      {email_value, password_value}
      when is_binary(email_value) and is_binary(password_value) ->
        user = Repo.get_by(User, email: email_value)

        case {user, User.valid_password?(user, password_value)} do
          {%User{confirmed_at: %DateTime{}}, true} -> user
          {_, true} -> nil
          {_, false} -> nil
        end

      _ ->
        nil
    end
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_user!(term()) :: User.t()
  def get_user!(id), do: Repo.get!(User, id)

  ## User registration

  @doc """
  Registers a user.

  ## Examples

      iex> register_user(%{field: value})
      {:ok, %User{}}

      iex> register_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  @spec register_user(map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def register_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for validating a Campfire token input.
  """
  @spec change_user_campfire_token(map()) :: Changeset.t()
  def change_user_campfire_token(attrs \\ %{}) do
    {%{}, %{campfire_token_input: :string}}
    |> Changeset.cast(attrs, [:campfire_token_input])
    |> Changeset.validate_required([:campfire_token_input])
    |> Changeset.validate_change(:campfire_token_input, fn :campfire_token_input, value ->
      case CampfireCredentials.normalize(value) do
        {:ok, _normalized_credentials} -> []
        {:error, message} -> [campfire_token_input: message]
      end
    end)
  end

  @doc """
  Stores an encrypted Campfire token for the given user.
  """
  @spec update_user_campfire_token(User.t(), map()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def update_user_campfire_token(user, attrs) do
    changeset = change_user_campfire_token(attrs)

    changeset =
      if admin?(user),
        do: changeset,
        else:
          Changeset.add_error(
            changeset,
            :campfire_token_input,
            "Only the administrator can manage the shared token."
          )

    case {user, changeset.valid?} do
      {%User{id: user_id}, true} ->
        token_input = Changeset.get_field(changeset, :campfire_token_input)
        {:ok, normalized_credentials} = CampfireCredentials.normalize(token_input)

        encrypted_credentials =
          CampfireCredentials.encrypt_user_credentials(user_id, normalized_credentials)

        user
        |> Changeset.change(encrypted_credentials: encrypted_credentials)
        |> Repo.update()

      _ ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes the stored Campfire token for the given user.
  """
  @spec delete_user_campfire_token(User.t()) :: {:ok, User.t()} | {:error, Changeset.t()}
  def delete_user_campfire_token(user) do
    if admin?(user) do
      user |> Changeset.change(encrypted_credentials: nil) |> Repo.update()
    else
      {:error,
       Changeset.add_error(
         Changeset.change(user),
         :encrypted_credentials,
         "Only the administrator can manage the shared token."
       )}
    end
  end

  @doc """
  Returns whether the user has a stored Campfire token.
  """
  @spec user_has_campfire_token?(User.t() | term()) :: boolean()
  def user_has_campfire_token?(user) do
    case user do
      %User{encrypted_credentials: encrypted_credentials} when is_map(encrypted_credentials) ->
        true

      _ ->
        false
    end
  end

  @doc """
  Decrypts the stored Campfire credentials for the given user.
  """
  @spec get_user_campfire_credentials(User.t()) ::
          {:ok, CampfireCredentials.normalized_credentials() | nil} | {:error, atom()}
  def get_user_campfire_credentials(user) do
    if admin?(user),
      do: CampfireCredentials.decrypt_user_credentials(user.id, user.encrypted_credentials),
      else: {:error, :forbidden}
  end

  @doc "Returns whether public registration is enabled."
  @spec public_signup_enabled?() :: boolean()
  def public_signup_enabled?, do: Application.get_env(:ca_tools, :public_signup_enabled, false)

  @doc "Checks the current database role rather than trusting a stale scope."
  @spec admin?(term()) :: boolean()
  def admin?(scope_or_user) do
    user =
      case scope_or_user do
        %CATools.Accounts.Scope{user: user} -> user
        %User{} = user -> user
        _ -> nil
      end

    case user do
      %User{id: id} when is_integer(id) ->
        Repo.exists?(from u in User, where: u.id == ^id and u.admin)

      _ ->
        false
    end
  end

  @doc "Reports whether installation needs its first administrator, awaits their password, or is ready."
  @spec installation_state() :: :empty | :pending | :ready
  def installation_state do
    if Application.get_env(:ca_tools, :initial_setup_enabled, true) do
      case Repo.all(
             from u in User, order_by: u.id, limit: 2, select: {u.admin, u.hashed_password}
           ) do
        [] -> :empty
        [{true, nil}] -> :pending
        _ -> :ready
      end
    else
      :ready
    end
  end

  @doc "Creates the first administrator and emails password setup instructions; concurrent requests cannot claim a second account."
  @spec setup_admin(map(), (String.t() -> String.t())) :: {:ok, User.t()} | {:error, term()}
  def setup_admin(attrs, url_fun) do
    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73190, 0)")

      if installation_state() == :empty do
        changeset =
          %User{}
          |> User.registration_changeset(Map.take(attrs, [:email, "email"]))
          |> Changeset.put_change(:admin, true)
          |> Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
          |> Changeset.unique_constraint(:admin, name: :users_single_admin_index)

        with {:ok, user} <- Repo.insert(changeset),
             {:ok, _email} <- deliver_password_setup_instructions(user, url_fun) do
          {:ok, user}
        end
      else
        {:error, :already_initialized}
      end
    end)
  end

  @doc "Sends a single-use, one-hour password setup link, returning a delivery error on failure."
  @spec deliver_password_setup_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_password_setup_instructions(user, url_fun) do
    {token, record} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(record)

    case UserNotifier.deliver_password_setup(user, url_fun.(token)) do
      {:ok, email} -> {:ok, email}
      {:error, reason} -> {:error, {:email_delivery, reason}}
    end
  end

  @doc "Creates a confirmed administrator from trusted deployment tooling. Never called by signup."
  @spec bootstrap_admin(String.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def bootstrap_admin(email, password) do
    user = Repo.get_by(User, email: email) || %User{}

    changeset =
      if user.id do
        User.password_changeset(user, %{password: password})
      else
        User.registration_changeset(user, %{email: email, password: password})
      end

    Repo.transact(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(73190, 0)")

      with {:ok, admin} <-
             changeset
             |> Changeset.validate_required([:hashed_password])
             |> Changeset.put_change(:admin, true)
             |> Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))
             |> Changeset.unique_constraint(:admin, name: :users_single_admin_index)
             |> Repo.insert_or_update() do
        Repo.delete_all(from t in UserToken, where: t.user_id == ^admin.id)
        {:ok, admin}
      end
    end)
  end

  @doc "Lists user accounts only for the administrator."
  @spec list_users(CATools.Accounts.Scope.t()) :: [User.t()]
  def list_users(scope) do
    if admin?(scope), do: Repo.all(from u in User, order_by: u.email), else: []
  end

  @doc "Creates a regular account and emails a single-use password setup link, only for the administrator. Rolls back on delivery failure."
  @spec create_user(CATools.Accounts.Scope.t(), map(), (String.t() -> String.t())) ::
          {:ok, User.t()} | {:error, term()}
  def create_user(scope, attrs, url_fun) do
    if admin?(scope) do
      Repo.transact(fn ->
        changeset =
          %User{}
          |> User.registration_changeset(Map.take(attrs, [:email, "email"]))
          |> Changeset.put_change(:admin, false)
          |> Changeset.put_change(:confirmed_at, DateTime.utc_now(:second))

        with {:ok, user} <- Repo.insert(changeset),
             {:ok, _email} <- deliver_password_setup_instructions(user, url_fun) do
          {:ok, user}
        end
      end)
    else
      {:error, :forbidden}
    end
  end

  @doc "Reports whether the administrator has configured shared Campfire access."
  @spec campfire_available?() :: boolean()
  def campfire_available? do
    Repo.exists?(from u in User, where: u.admin and not is_nil(u.encrypted_credentials))
  end

  @doc "Loads shared Campfire credentials for an authenticated import owner, without copying them onto the owner."
  @spec shared_campfire_credentials(User.t()) ::
          {:ok, CampfireCredentials.normalized_credentials() | nil} | {:error, atom()}
  def shared_campfire_credentials(user) do
    if Repo.exists?(from u in User, where: u.id == ^user.id) do
      case Repo.one(from u in User, where: u.admin) do
        nil ->
          {:ok, nil}

        admin ->
          CampfireCredentials.decrypt_user_credentials(admin.id, admin.encrypted_credentials)
      end
    else
      {:error, :not_found}
    end
  end

  @doc "Deletes the authenticated account and its exclusive files only after exact email confirmation."
  @spec delete_account(CATools.Accounts.Scope.t(), term()) ::
          {:ok, [UserToken.t()]} | {:error, term()}
  def delete_account(scope, confirmation) do
    user = Repo.get(User, scope.user.id)

    if user && is_binary(confirmation) &&
         String.downcase(String.trim(confirmation)) == String.downcase(user.email) do
      result =
        Repo.transact(fn ->
          Repo.query!("SELECT pg_advisory_xact_lock(73191, $1)", [user.id])

          CATools.Maps.ImageCache.with_storage_lock(fn ->
            maps = Repo.all(from m in CATools.Maps.UserMap, where: m.user_id == ^user.id)
            map_ids = Enum.map(maps, & &1.id)

            sources =
              Repo.all(
                from s in CATools.Maps.MapSource, where: s.map_id in ^map_ids, select: s.id
              )

            communities =
              Repo.all(from c in CATools.Communities.Community, where: c.user_id == ^user.id)

            community_ids = Enum.map(communities, & &1.id)
            tokens = Repo.all(from t in UserToken, where: t.user_id == ^user.id)

            own_urls =
              Repo.all(
                from p in CATools.Maps.MapPoint,
                  where: p.map_id in ^map_ids,
                  select: {p.cover_photo_url, p.host_avatar_url}
              )
              |> Enum.flat_map(fn {cover, avatar} -> [cover, avatar] end)
              |> Kernel.++(Enum.map(communities, & &1.avatar_url))
              |> Enum.map(&CATools.Maps.ImageURL.normalize/1)
              |> Enum.reject(&is_nil/1)

            own_ids =
              Enum.map(own_urls, &CATools.Maps.ImageCache.key/1) ++
                Enum.map(maps, & &1.image_id) ++
                Repo.all(
                  from u in CATools.Maps.ImageUpload,
                    where: u.user_id == ^user.id,
                    select: u.image_id
                )

            retained_urls =
              Repo.all(
                from p in CATools.Maps.MapPoint,
                  where: p.map_id not in ^map_ids,
                  select: {p.cover_photo_url, p.host_avatar_url}
              )
              |> Enum.flat_map(fn {cover, avatar} -> [cover, avatar] end)
              |> Kernel.++(
                Repo.all(
                  from c in CATools.Communities.Community,
                    where: c.user_id != ^user.id,
                    select: c.avatar_url
                )
              )
              |> Enum.map(&CATools.Maps.ImageURL.normalize/1)
              |> Enum.reject(&is_nil/1)

            retained_ids =
              Enum.map(retained_urls, &CATools.Maps.ImageCache.key/1) ++
                Repo.all(
                  from m in CATools.Maps.UserMap,
                    where: m.user_id != ^user.id and not is_nil(m.image_id),
                    select: m.image_id
                ) ++
                Repo.all(
                  from u in CATools.Maps.ImageUpload,
                    where: u.user_id != ^user.id,
                    select: u.image_id
                )

            redirects =
              Repo.all(
                from i in CATools.Maps.CachedImage,
                  where: not is_nil(i.redirect_url),
                  select: {i.id, i.redirect_url}
              )

            {owned, retained} =
              Enum.reduce(
                1..5,
                {MapSet.new(Enum.reject(own_ids, &is_nil/1)), MapSet.new(retained_ids)},
                fn _, {owned, retained} ->
                  Enum.reduce(redirects, {owned, retained}, fn {origin, target},
                                                               {owned, retained} ->
                    target_id = CATools.Maps.ImageCache.key(target)

                    {if(MapSet.member?(owned, origin),
                       do: MapSet.put(owned, target_id),
                       else: owned
                     ),
                     if(MapSet.member?(retained, origin),
                       do: MapSet.put(retained, target_id),
                       else: retained
                     )}
                  end)
                end
              )

            exclusive = MapSet.difference(owned, retained) |> MapSet.to_list()
            source_ids = Enum.map(sources, &to_string/1)
            group_ids = Enum.map(community_ids, &to_string/1)

            jobs =
              Repo.all(
                from j in Oban.Job,
                  where:
                    fragment("?->>'user_id'", j.args) == ^to_string(user.id) or
                      fragment("?->>'source_id'", j.args) in ^source_ids or
                      fragment("?->>'community_id'", j.args) in ^group_ids,
                  select: j.id
              )

            image_jobs =
              Repo.all(
                from j in Oban.Job,
                  where: j.worker == "CATools.Campfire.ImageCacheJob",
                  select: {j.id, j.args}
              )
              |> Enum.filter(fn {_id, args} ->
                url = CATools.Maps.ImageURL.normalize(args["url"])
                url && CATools.Maps.ImageCache.key(url) in exclusive
              end)
              |> Enum.map(&elem(&1, 0))

            Enum.each(jobs ++ image_jobs, &Oban.cancel_job/1)
            Repo.delete_all(from j in Oban.Job, where: j.id in ^(jobs ++ image_jobs))

            Repo.delete_all(
              from i in CATools.Communities.Invitation,
                where: fragment("lower(?)", i.email) == ^String.downcase(user.email)
            )

            # Foreign keys cascade through maps, sources, points, selections, batches,
            # import windows, communities, invitations, login tokens and upload ownership.
            Repo.delete!(user)

            Enum.each(exclusive, fn id ->
              case File.rm(Path.join(CATools.Maps.ImageCache.directory(), id)) do
                :ok -> :ok
                {:error, :enoent} -> :ok
                {:error, reason} -> Repo.rollback({:file_cleanup, reason})
              end
            end)

            Repo.delete_all(from i in CATools.Maps.CachedImage, where: i.id in ^exclusive)
            {:ok, tokens}
          end)
        end)

      if match?({:ok, _}, result), do: CATools.Maps.notify(user.id)
      result
    else
      {:error, :confirmation_required}
    end
  end

  ## Settings

  @doc """
  Checks whether the user is in sudo mode.

  The user is in sudo mode when the last authentication was done no further
  than 20 minutes ago. The limit can be given as second argument in minutes.
  """
  @spec sudo_mode?(User.t() | term(), integer()) :: boolean()
  def sudo_mode?(user, minutes \\ -20) do
    case user do
      %User{authenticated_at: %DateTime{} = authenticated_at} ->
        DateTime.after?(authenticated_at, DateTime.utc_now() |> DateTime.add(minutes, :minute))

      _ ->
        false
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user email.

  See `CATools.Accounts.User.email_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_email(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_email(User.t(), map(), keyword()) :: Changeset.t()
  def change_user_email(user, attrs \\ %{}, opts \\ []) do
    User.email_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user email using the given token.

  If the token matches, the user email is updated and the token is deleted.
  """
  @spec update_user_email(User.t(), String.t()) :: {:ok, User.t()} | {:error, term()}
  def update_user_email(user, token) do
    context = "change:#{user.email}"

    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_change_email_token_query(token, context),
           %UserToken{sent_to: email} <- Repo.one(query),
           {:ok, user} <- Repo.update(User.email_changeset(user, %{email: email})),
           {_count, _result} <-
             Repo.delete_all(from(UserToken, where: [user_id: ^user.id, context: ^context])) do
        {:ok, user}
      else
        _ -> {:error, :transaction_aborted}
      end
    end)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for changing the user password.

  See `CATools.Accounts.User.password_changeset/3` for a list of supported options.

  ## Examples

      iex> change_user_password(user)
      %Ecto.Changeset{data: %User{}}

  """
  @spec change_user_password(User.t(), map(), keyword()) :: Changeset.t()
  def change_user_password(user, attrs \\ %{}, opts \\ []) do
    User.password_changeset(user, attrs, opts)
  end

  @doc """
  Updates the user password.

  Returns a tuple with the updated user, as well as a list of expired tokens.

  ## Examples

      iex> update_user_password(user, %{password: ...})
      {:ok, {%User{}, [...]}}

      iex> update_user_password(user, %{password: "too short"})
      {:error, %Ecto.Changeset{}}

  """
  @spec update_user_password(User.t(), map()) ::
          token_disconnect_result() | {:error, Changeset.t()}
  def update_user_password(user, attrs) do
    user
    |> User.password_changeset(attrs)
    |> update_user_and_delete_all_tokens()
  end

  @doc "Builds a signup changeset without storing a user."
  @spec change_user_registration(map(), keyword()) :: Changeset.t()
  def change_user_registration(attrs \\ %{}, opts \\ []) do
    User.registration_changeset(%User{}, attrs, opts)
  end

  @doc "Sends the appropriate signup confirmation for password or email-only registration."
  @spec deliver_signup_instructions(User.t(), (String.t() -> String.t()), (String.t() ->
                                                                             String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_signup_instructions(user, login_url, confirm_url) do
    case user.hashed_password do
      nil ->
        deliver_login_instructions(user, login_url)

      _ ->
        {token, record} = UserToken.build_email_token(user, "confirm")
        Repo.insert!(record)
        UserNotifier.deliver_account_confirmation(user, confirm_url.(token))
    end
  end

  @doc "Confirms a password signup using a single-use email token."
  @spec confirm_user(String.t()) :: {:ok, User.t()} | {:error, term()}
  def confirm_user(token) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_email_token_query(token, "confirm", 86_400),
           {user, _record} <- Repo.one(from q in query, lock: "FOR UPDATE"),
           {:ok, user} <- Repo.update(User.confirm_changeset(user)) do
        Repo.delete_all(
          from t in UserToken, where: t.user_id == ^user.id and t.context == "confirm"
        )

        {:ok, user}
      else
        _ -> {:error, :invalid_token}
      end
    end)
  end

  @doc "Sends a one-hour password recovery link to a confirmed account."
  @spec deliver_password_reset_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_password_reset_instructions(user, url_fun) do
    {token, record} = UserToken.build_email_token(user, "reset_password")
    Repo.insert!(record)
    UserNotifier.deliver_password_reset(user, url_fun.(token))
  end

  @doc "Returns the user for a valid recovery token, or nil."
  @spec get_user_by_password_reset_token(String.t()) :: User.t() | nil
  def get_user_by_password_reset_token(token) do
    with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password", 3600),
         {%User{confirmed_at: confirmed} = user, _record} when not is_nil(confirmed) <-
           Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc "Resets a password and revokes all existing login, recovery and session tokens."
  @spec reset_user_password(String.t(), map()) :: token_disconnect_result() | {:error, term()}
  def reset_user_password(token, attrs) do
    Repo.transact(fn ->
      with {:ok, query} <- UserToken.verify_email_token_query(token, "reset_password", 3600),
           {%User{confirmed_at: confirmed} = user, _record} when not is_nil(confirmed) <-
             Repo.one(from q in query, lock: "FOR UPDATE") do
        update_user_password(user, attrs)
      else
        _ -> {:error, :invalid_token}
      end
    end)
  end

  ## Session

  @doc """
  Generates a session token.
  """
  @spec generate_user_session_token(User.t()) :: binary()
  def generate_user_session_token(user) do
    {token, user_token} = UserToken.build_session_token(user)
    Repo.insert!(user_token)
    token
  end

  @doc """
  Gets the user with the given signed token.

  If the token is valid `{user, token_inserted_at}` is returned, otherwise `nil` is returned.
  """
  @spec get_user_by_session_token(binary()) :: session_lookup_result()
  def get_user_by_session_token(token) do
    {:ok, query} = UserToken.verify_session_token_query(token)
    Repo.one(query)
  end

  @doc """
  Gets the user with the given magic link token.
  """
  @spec get_user_by_magic_link_token(binary()) :: User.t() | nil
  def get_user_by_magic_link_token(token) do
    with {:ok, query} <- UserToken.verify_magic_link_token_query(token),
         {user, _token} <- Repo.one(query) do
      user
    else
      _ -> nil
    end
  end

  @doc """
  Logs the user in by magic link.

  There are three cases to consider:

  1. The user has already confirmed their email. They are logged in
     and the magic link is expired.

  2. The user has not confirmed their email and no password is set.
     In this case, the user gets confirmed, logged in, and all tokens -
     including session ones - are expired. In theory, no other tokens
     exist but we delete all of them for best security practices.

  3. The user has not confirmed their email but a password is set.
     This cannot happen in the default implementation but may be the
     source of security pitfalls. See the "Mixing magic link and password registration" section of
     `mix help phx.gen.auth`.
  """
  @spec login_user_by_magic_link(binary()) :: token_disconnect_result() | {:error, :not_found}
  def login_user_by_magic_link(token) do
    {:ok, query} = UserToken.verify_magic_link_token_query(token)

    case Repo.one(query) do
      # Prevent session fixation attacks by disallowing magic links for unconfirmed users with password
      {%User{confirmed_at: nil, hashed_password: hash}, _token} when not is_nil(hash) ->
        raise """
        magic link log in is not allowed for unconfirmed users with a password set!

        This cannot happen with the default implementation, which indicates that you
        might have adapted the code to a different use case. Please make sure to read the
        "Mixing magic link and password registration" section of `mix help phx.gen.auth`.
        """

      {%User{confirmed_at: nil} = user, _token} ->
        user
        |> User.confirm_changeset()
        |> update_user_and_delete_all_tokens()

      {user, token} ->
        Repo.delete!(token)
        {:ok, {user, []}}

      nil ->
        {:error, :not_found}
    end
  end

  @doc ~S"""
  Delivers the update email instructions to the given user.

  ## Examples

      iex> deliver_user_update_email_instructions(user, current_email, &url(~p"/auth/users/settings/confirm-email/#{&1}"))
      {:ok, %{to: ..., body: ...}}

  """
  @spec deliver_user_update_email_instructions(User.t(), String.t(), (String.t() -> String.t())) ::
          {:ok, term()} | {:error, term()}
  def deliver_user_update_email_instructions(user, current_email, update_email_url_fun) do
    case {user, is_function(update_email_url_fun, 1)} do
      {%User{}, true} ->
        {encoded_token, user_token} = UserToken.build_email_token(user, "change:#{current_email}")

        Repo.insert!(user_token)
        UserNotifier.deliver_update_email_instructions(user, update_email_url_fun.(encoded_token))

      _ ->
        {:error, :invalid_arguments}
    end
  end

  @doc """
  Delivers the magic link login instructions to the given user.
  """
  @spec deliver_login_instructions(User.t(), (String.t() -> String.t())) ::
          {:ok, term()} | {:error, term()}
  def deliver_login_instructions(user, magic_link_url_fun) do
    case {user, is_function(magic_link_url_fun, 1)} do
      {%User{}, true} ->
        {encoded_token, user_token} = UserToken.build_email_token(user, "login")
        Repo.insert!(user_token)
        UserNotifier.deliver_login_instructions(user, magic_link_url_fun.(encoded_token))

      _ ->
        {:error, :invalid_arguments}
    end
  end

  @doc """
  Deletes the signed token with the given context.
  """
  @spec delete_user_session_token(binary()) :: :ok
  def delete_user_session_token(token) do
    Repo.delete_all(from(UserToken, where: [token: ^token, context: "session"]))
    :ok
  end

  ## Token helper

  defp update_user_and_delete_all_tokens(changeset) do
    Repo.transact(fn ->
      with {:ok, user} <- Repo.update(changeset) do
        tokens_to_expire = Repo.all_by(UserToken, user_id: user.id)

        Repo.delete_all(from(t in UserToken, where: t.id in ^Enum.map(tokens_to_expire, & &1.id)))

        {:ok, {user, tokens_to_expire}}
      end
    end)
  end
end
