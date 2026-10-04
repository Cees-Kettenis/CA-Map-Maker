defmodule CAToolsWeb.Router do
  use CAToolsWeb, :router

  import CAToolsWeb.Auth.UserAuth

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {CAToolsWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug :fetch_current_scope_for_user
    plug :require_initial_setup
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", CAToolsWeb do
    pipe_through :browser

    get "/setup", SetupController, :show
    post "/setup", SetupController, :create
    get "/", PageController, :home
    get "/media/meetups/:id", MeetupImageController, :show
    get "/maps/:slug/points", MapController, :public_points
    get "/maps/:slug/export.kml", MapController, :public_export

    live_session :public_maps, on_mount: [{CAToolsWeb.Auth.UserAuth, :mount_current_scope}] do
      live "/maps/:slug", MapLive.Public, :show
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", CAToolsWeb do
  #   pipe_through :api
  # end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:ca_tools, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: CAToolsWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end

  ## Authentication routes

  scope "/auth", CAToolsWeb.Auth do
    pipe_through [:browser, :redirect_if_user_is_authenticated]

    post "/users/register", UserRegistrationController, :create
  end

  scope "/auth", CAToolsWeb.Auth do
    pipe_through [:browser, :require_authenticated_user]

    put "/users/settings", UserSettingsController, :update
    delete "/users/account", UserAccountController, :delete
  end

  scope "/auth", CAToolsWeb.Auth do
    pipe_through [:browser]

    get "/users/confirm/:token", UserRecoveryController, :confirm
    post "/users/reset-password/:token", UserRecoveryController, :reset
    post "/users/log-in", UserSessionController, :create
    delete "/users/log-out", UserSessionController, :delete
  end

  scope "/", CAToolsWeb do
    pipe_through [:browser, :require_authenticated_user]

    get "/dashboard/maps/:id/export.kml", MapController, :owner_export
    get "/community/maps/:id/export.kml", MapController, :community_export

    live_session :authenticated_maps,
      on_mount: [{CAToolsWeb.Auth.UserAuth, :require_authenticated}] do
      live "/dashboard/community", CommunityLive.Index, :index
      live "/community/maps/:id", MapLive.Public, :community
      live "/dashboard/maps", MapLive.Index, :index
      live "/dashboard/maps/:id", MapLive.Show, :show
    end
  end

  scope "/", CAToolsWeb do
    pipe_through [:browser, :require_authenticated_user, :require_admin]

    live_session :admin_accounts, on_mount: [{CAToolsWeb.Auth.UserAuth, :require_admin}] do
      live "/dashboard/users", Admin.Users, :index
    end
  end

  ## Authentication routes

  scope "/auth", CAToolsWeb.Auth do
    pipe_through [:browser, :require_authenticated_user]

    live_session :require_authenticated_user,
      on_mount: [{CAToolsWeb.Auth.UserAuth, :require_authenticated}] do
      live "/users/settings", UserLive.Settings, :edit
      live "/users/settings/confirm-email/:token", UserLive.Settings, :confirm_email
    end

    post "/users/update-password", UserSessionController, :update_password
  end

  scope "/auth", CAToolsWeb.Auth do
    pipe_through [:browser]

    live_session :current_user,
      on_mount: [{CAToolsWeb.Auth.UserAuth, :mount_current_scope}] do
      live "/users/reset-password", UserLive.Recovery, :request
      live "/users/reset-password/:token", UserLive.Recovery, :reset
      live "/users/register", UserLive.Registration, :new
      live "/users/log-in", UserLive.Login, :new
      live "/users/log-in/:token", UserLive.Confirmation, :new
    end
  end
end
