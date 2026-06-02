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
    |> User.email_changeset(attrs)
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
    user
    |> Changeset.change(encrypted_credentials: nil)
    |> Repo.update()
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
    CampfireCredentials.decrypt_user_credentials(user.id, user.encrypted_credentials)
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
