defmodule CAToolsWeb.Auth.UserAuth do
  use CAToolsWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias CATools.Accounts
  alias CATools.Accounts.Scope

  # Make the remember me cookie valid for 14 days. This should match
  # the session validity setting in UserToken.
  @max_cookie_age_in_days 14
  @remember_me_cookie "_ca_tools_web_user_remember_me"
  @remember_me_options [
    sign: true,
    max_age: @max_cookie_age_in_days * 24 * 60 * 60,
    same_site: "Lax"
  ]

  # How old the session token should be before a new one is issued. When a request is made
  # with a session token older than this value, then a new session token will be created
  # and the session and remember-me cookies (if set) will be updated with the new token.
  # Lowering this value will result in more tokens being created by active users. Increasing
  # it will result in less time before a session token expires for a user to get issued a new
  # token. This can be set to a value greater than `@max_cookie_age_in_days` to disable
  # the reissuing of tokens completely.
  @session_reissue_age_in_days 7

  @doc """
  Logs the user in.

  Redirects to the session's `:user_return_to` path
  or falls back to the `signed_in_path/1`.
  """
  @spec log_in_user(Plug.Conn.t(), CATools.Accounts.User.t(), map()) :: Plug.Conn.t()
  def log_in_user(conn, user, params \\ %{}) do
    user_return_to = get_session(conn, :user_return_to)

    conn
    |> create_or_extend_session(user, params)
    |> redirect(to: user_return_to || signed_in_path(conn))
  end

  @doc """
  Logs the user out.

  It clears all session data for safety. See renew_session.
  """
  @spec log_out_user(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_user(conn) do
    user_token = get_session(conn, :user_token)
    user_token && Accounts.delete_user_session_token(user_token)

    if live_socket_id = get_session(conn, :live_socket_id) do
      CAToolsWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

    conn
    |> renew_session(nil)
    |> delete_resp_cookie(@remember_me_cookie, @remember_me_options)
    |> redirect(to: ~p"/")
  end

  @doc """
  Authenticates the user by looking into the session and remember me token.

  Will reissue the session token if it is older than the configured age.
  """
  @spec fetch_current_scope_for_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_scope_for_user(conn, _opts) do
    with {token, conn} <- ensure_user_token(conn),
         {user, token_inserted_at} <- Accounts.get_user_by_session_token(token) do
      conn
      |> assign(:current_scope, Scope.for_user(user))
      |> maybe_reissue_user_session_token(user, token_inserted_at)
    else
      nil -> assign(conn, :current_scope, Scope.for_user(nil))
    end
  end

  defp ensure_user_token(conn) do
    if token = get_session(conn, :user_token) do
      {token, conn}
    else
      conn = fetch_cookies(conn, signed: [@remember_me_cookie])

      if token = conn.cookies[@remember_me_cookie] do
        {token, conn |> put_token_in_session(token) |> put_session(:user_remember_me, true)}
      else
        nil
      end
    end
  end

  # Reissue the session token if it is older than the configured reissue age.
  defp maybe_reissue_user_session_token(conn, user, token_inserted_at) do
    token_age = DateTime.diff(DateTime.utc_now(:second), token_inserted_at, :day)

    if token_age >= @session_reissue_age_in_days do
      create_or_extend_session(conn, user, %{})
    else
      conn
    end
  end

  # This function is the one responsible for creating session tokens
  # and storing them safely in the session and cookies. It may be called
  # either when logging in, during sudo mode, or to renew a session which
  # will soon expire.
  #
  # When the session is created, rather than extended, the renew_session
  # function will clear the session to avoid fixation attacks. See the
  # renew_session function to customize this behaviour.
  defp create_or_extend_session(conn, user, params) do
    token = Accounts.generate_user_session_token(user)
    remember_me = get_session(conn, :user_remember_me)

    conn
    |> renew_session(user)
    |> put_token_in_session(token)
    |> maybe_write_remember_me_cookie(token, params, remember_me)
  end

  # Do not renew session if the user is already logged in
  # to prevent CSRF errors or data being lost in tabs that are still open
  defp renew_session(conn, user) do
    case conn.assigns do
      %{current_scope: %{user: %{id: current_user_id}}} when current_user_id == user.id ->
        conn

      _ ->
        delete_csrf_token()

        conn
        |> configure_session(renew: true)
        |> clear_session()
    end
  end

  defp maybe_write_remember_me_cookie(conn, token, params, remember_me?) do
    case {params, remember_me?} do
      {%{"remember_me" => "true"}, _} ->
        write_remember_me_cookie(conn, token)

      {_, true} ->
        write_remember_me_cookie(conn, token)

      _ ->
        conn
    end
  end

  defp write_remember_me_cookie(conn, token) do
    conn
    |> put_session(:user_remember_me, true)
    |> put_resp_cookie(@remember_me_cookie, token, @remember_me_options)
  end

  defp put_token_in_session(conn, token) do
    conn
    |> put_session(:user_token, token)
    |> put_session(:live_socket_id, user_session_topic(token))
  end

  @doc """
  Disconnects existing sockets for the given tokens.
  """
  @spec disconnect_sessions([map()]) :: :ok
  def disconnect_sessions(tokens) do
    Enum.each(tokens, fn %{token: token} ->
      CAToolsWeb.Endpoint.broadcast(user_session_topic(token), "disconnect", %{})
    end)

    :ok
  end

  defp user_session_topic(token), do: "users_sessions:#{Base.url_encode64(token)}"

  @doc """
  Handles mounting and authenticating the current_scope in LiveViews.

  ## `on_mount` arguments

    * `:mount_current_scope` - Assigns current_scope
      to socket assigns based on user_token, or nil if
      there's no user_token or no matching user.

    * `:require_authenticated` - Authenticates the user from the session,
      and assigns the current_scope to socket assigns based
      on user_token.
      Redirects to login page if there's no logged user.

  ## Examples

  Use the `on_mount` lifecycle macro in LiveViews to mount or authenticate
  the `current_scope`:

      defmodule CAToolsWeb.PageLive do
        use CAToolsWeb, :live_view

        on_mount {CAToolsWeb.Auth.UserAuth, :mount_current_scope}
        ...
      end

  Or use the `live_session` of your router to invoke the on_mount callback:

      live_session :authenticated, on_mount: [{CAToolsWeb.Auth.UserAuth, :require_authenticated}] do
      live "/profile", ProfileLive, :index
      end
  """
  @spec on_mount(atom(), map(), map(), Phoenix.LiveView.Socket.t()) ::
          {:cont, Phoenix.LiveView.Socket.t()} | {:halt, Phoenix.LiveView.Socket.t()}
  def on_mount(hook, _params, session, socket) do
    mounted_socket = mount_current_scope(socket, session)

    case hook do
      :mount_current_scope ->
        {:cont, mounted_socket}

      :require_authenticated ->
        case mounted_socket.assigns.current_scope && mounted_socket.assigns.current_scope.user do
          nil ->
            redirected_socket =
              mounted_socket
              |> Phoenix.LiveView.put_flash(:error, "You must log in to access this page.")
              |> Phoenix.LiveView.redirect(to: ~p"/auth/users/log-in")

            {:halt, redirected_socket}

          _user ->
            {:cont, mounted_socket}
        end

      :require_sudo_mode ->
        case Accounts.sudo_mode?(mounted_socket.assigns.current_scope.user, -10) do
          true ->
            {:cont, mounted_socket}

          false ->
            redirected_socket =
              mounted_socket
              |> Phoenix.LiveView.put_flash(
                :error,
                "You must re-authenticate to access this page."
              )
              |> Phoenix.LiveView.redirect(to: ~p"/auth/users/log-in")

            {:halt, redirected_socket}
        end
    end
  end

  defp mount_current_scope(socket, session) do
    Phoenix.Component.assign_new(socket, :current_scope, fn ->
      {user, _} =
        if user_token = session["user_token"] do
          Accounts.get_user_by_session_token(user_token)
        end || {nil, nil}

      Scope.for_user(user)
    end)
  end

  @doc "Returns the path to redirect to after log in."
  # the user was already logged in, redirect to settings
  @spec signed_in_path(Plug.Conn.t() | term()) :: String.t()
  def signed_in_path(conn_or_socket) do
    case conn_or_socket do
      %Plug.Conn{assigns: %{current_scope: %Scope{user: %Accounts.User{}}}} ->
        ~p"/auth/users/settings"

      _ ->
        ~p"/"
    end
  end

  @doc """
  Plug for routes that require the user to be authenticated.
  """
  @spec require_authenticated_user(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_user(conn, _opts) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user do
      conn
    else
      conn
      |> put_flash(:error, "You must log in to access this page.")
      |> maybe_store_return_to()
      |> redirect(to: ~p"/auth/users/log-in")
      |> halt()
    end
  end

  @doc "Redirects authenticated users away from guest-only pages."
  @spec redirect_if_user_is_authenticated(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def redirect_if_user_is_authenticated(conn, _opts) do
    case conn.assigns.current_scope && conn.assigns.current_scope.user do
      nil ->
        conn

      _user ->
        conn
        |> redirect(to: signed_in_path(conn))
        |> halt()
    end
  end

  @doc "Requires sudo mode before allowing access to sensitive controller routes."
  @spec require_sudo_mode(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_sudo_mode(conn, _opts) do
    current_user = get_in(conn.assigns, [:current_scope, Access.key(:user)])

    case Accounts.sudo_mode?(current_user, -10) do
      true ->
        conn

      false ->
        conn
        |> put_flash(:error, "You must re-authenticate to access this page.")
        |> maybe_store_return_to()
        |> redirect(to: ~p"/auth/users/log-in")
        |> halt()
    end
  end

  defp maybe_store_return_to(conn) do
    case conn.method do
      "GET" ->
        put_session(conn, :user_return_to, current_path(conn))

      _ ->
        conn
    end
  end
end
