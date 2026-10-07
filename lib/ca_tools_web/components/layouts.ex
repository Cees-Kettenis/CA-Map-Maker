defmodule CAToolsWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use CAToolsWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :setup, :boolean, default: false
  attr :compact, :boolean, default: false, doc: "uses tighter mobile spacing on map pages"

  slot :inner_block, required: true

  @spec app(map()) :: Phoenix.LiveView.Rendered.t()
  def app(assigns) do
    ~H"""
    <header class={["atlas-nav", @compact && "atlas-nav-compact"]}>
      <a href={~p"/"} class="atlas-brand" aria-label="Pogo Meetups home">
        <span class="atlas-brand-mark"><.icon name="hero-map" class="size-5" /></span>
        <span>Pogo<span class="font-normal opacity-60"> Meetups</span></span>
      </a>
      <.navigation current_scope={@current_scope} setup={@setup} />
      <details
        id="mobile-navigation"
        class="atlas-mobile-navigation"
        phx-mounted={JS.ignore_attributes("open")}
        phx-click-away={JS.remove_attribute("open", to: "#mobile-navigation")}
        phx-window-keydown={JS.remove_attribute("open", to: "#mobile-navigation")}
        phx-key="Escape"
      >
        <summary class="atlas-button" aria-label="Navigation menu">
          <.icon name="hero-bars-3" class="size-5" /> Menu
        </summary>
        <.navigation current_scope={@current_scope} setup={@setup} mobile />
      </details>
    </header>
    <main class={["atlas-main", @compact && "atlas-main-compact"]}>
      {render_slot(@inner_block)}
    </main>
    <footer class="atlas-footer">
      <span>Pogo Meetups · Independent community tool</span>
    </footer>

    <.flash_group flash={@flash} />
    """
  end

  attr :current_scope, :map, default: nil
  attr :setup, :boolean, default: false
  attr :mobile, :boolean, default: false
  @doc "Renders account navigation for the desktop bar or mobile menu."
  @spec navigation(map()) :: Phoenix.LiveView.Rendered.t()
  def navigation(assigns) do
    ~H"""
    <nav
      aria-label={if @mobile, do: "Mobile navigation", else: "Main navigation"}
      phx-click={@mobile && JS.remove_attribute("open", to: "#mobile-navigation")}
      class={
        if @mobile,
          do: "atlas-mobile-navigation-menu text-sm",
          else: "atlas-desktop-navigation flex items-center gap-5 text-sm"
      }
    >
      <%= if @current_scope && !@setup do %>
        <.link navigate={~p"/dashboard/community"} class="nav-link"><.icon
          :if={@mobile}
          name="hero-user-group"
          class="size-4"
        />My Communities</.link>
        <.link navigate={~p"/dashboard/maps"} class="nav-link"><.icon
          :if={@mobile}
          name="hero-map"
          class="size-4"
        />My Maps</.link>
        <.link :if={@current_scope.user.admin} navigate={~p"/dashboard/users"} class="nav-link"><.icon
          :if={@mobile}
          name="hero-users"
          class="size-4"
        />Accounts</.link>
        <.link navigate={~p"/auth/users/settings"} class="nav-link"><.icon
          :if={@mobile}
          name="hero-cog-6-tooth"
          class="size-4"
        />Settings</.link>
        <.link href={~p"/auth/users/log-out"} method="delete" class="nav-link"><.icon
          :if={@mobile}
          name="hero-arrow-right-start-on-rectangle"
          class="size-4"
        />Log out</.link>
      <% else %>
        <.link :if={!@setup} navigate={~p"/auth/users/log-in"} class="nav-link">Log in</.link>
        <.link
          :if={!@setup && CATools.Accounts.public_signup_enabled?()}
          navigate={~p"/auth/users/register"}
          class="btn btn-primary btn-sm"
        >Get started <.icon name="hero-arrow-up-right" class="size-4" /></.link>
      <% end %>
      <div class={if @mobile, do: "atlas-mobile-theme", else: "hidden md:block"}>
        <span :if={@mobile} class="text-xs opacity-65">Appearance</span>
        <.theme_toggle />
      </div>
    </nav>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  @spec flash_group(map()) :: Phoenix.LiveView.Rendered.t()
  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  @spec theme_toggle(map()) :: Phoenix.LiveView.Rendered.t()
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="system"
        aria-label="Use system theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="light"
        aria-label="Use light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        data-phx-theme="dark"
        aria-label="Use dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
