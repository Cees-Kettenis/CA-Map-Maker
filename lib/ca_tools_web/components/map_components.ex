defmodule CAToolsWeb.MapComponents do
  @moduledoc "Shared geographic map and point components."
  use CAToolsWeb, :html

  @external_resource Path.expand("../../../priv/static/images/atlas-map.svg", __DIR__)
  @map_illustration File.read!(@external_resource)

  @doc "Renders the local SVG illustration inline so its route and pins can be animated."
  @spec map_illustration(map()) :: Phoenix.LiveView.Rendered.t()
  def map_illustration(assigns) do
    assigns = assign(assigns, :illustration, @map_illustration)

    ~H"""
    <div class="atlas-hero-art" aria-hidden="true">{Phoenix.HTML.raw(@illustration)}</div>
    """
  end

  attr :map, :any, required: true
  attr :event, :string, default: "update_now"
  @doc "Displays update times and a manual refresh action without internal batch details."
  @spec update_summary(map()) :: Phoenix.LiveView.Rendered.t()
  def update_summary(assigns) do
    assigns =
      assign(assigns,
        next_update: CATools.Maps.next_update_at(assigns.map),
        last_update:
          assigns.map.last_imported_at ||
            (assigns.map.community && assigns.map.community.last_checked_at)
      )

    ~H"""
    <div class="space-y-5">
      <h2 class="text-xl font-semibold">Updates</h2>
      <div class="space-y-2 text-sm">
        <p class="opacity-65">Last updated</p>
        <.local_time
          :if={@last_update}
          id={"updated-#{@map.id}"}
          datetime={@last_update}
        />
        <p :if={!@last_update}>Not updated yet</p>
      </div>
      <div class="space-y-2 text-sm">
        <p class="opacity-65">Scheduled update</p>
        <.local_time :if={@next_update} id={"scheduled-#{@map.id}"} datetime={@next_update} />
        <p :if={!@next_update}>Not scheduled</p>
      </div>
      <button
        phx-click={@event}
        phx-disable-with="Starting..."
        class="atlas-button atlas-button-primary"
      >Update now</button>
    </div>
    """
  end

  attr :map, :any, required: true
  @doc "Renders a map title with its locally stored image or community logo."
  @spec map_identity(map()) :: Phoenix.LiveView.Rendered.t()
  def map_identity(assigns) do
    assigns = assign(assigns, :image, CATools.Maps.image_url(assigns.map))

    ~H"""
    <div class="flex items-center gap-4 min-w-0">
      <img
        :if={@image}
        src={@image}
        alt=""
        class="size-16 sm:size-20 rounded-2xl object-contain shrink-0"
      />
      <div class="min-w-0">
        <h1 class="atlas-display text-3xl">{@map.name}</h1>
        <p :if={@map.description not in [nil, ""]} class="mt-3 text-sm opacity-65 max-w-xl">
          {@map.description}
        </p>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :event, :string, required: true
  attr :community, :boolean, default: false
  attr :target_id, :integer, required: true
  @doc "Renders a styled deletion dialog with keyboard focus managed by the browser."
  @spec delete_confirmation(map()) :: Phoenix.LiveView.Rendered.t()
  def delete_confirmation(assigns) do
    ~H"""
    <dialog
      id={@id}
      data-target-id={@target_id}
      phx-hook="ConfirmDialog"
      class="atlas-dialog"
      aria-labelledby={@id <> "-title"}
    >
      <span class="atlas-delete-symbol"><.icon name="hero-trash" class="size-6" /></span>
      <h2 id={@id <> "-title"} class="text-xl font-semibold mt-5">
        Delete {if @community, do: "community", else: "map"}?
      </h2>
      <p class="text-sm opacity-70 mt-3">“{@name}” and its imported locations will be removed.</p>
      <p :if={@community} class="text-sm opacity-70 mt-2">
        Monitoring stops and private invitations are removed. Linked date maps will update.
      </p>
      <p class="text-xs opacity-60 mt-3">This cannot be undone.</p>
      <div class="flex justify-end gap-3 mt-7">
        <form method="dialog"><button class="atlas-button">Keep it</button></form>
        <button
          phx-click={@event}
          phx-value-id={@target_id}
          phx-disable-with="Deleting..."
          class="atlas-button atlas-button-danger"
        >Delete {if @community, do: "community", else: "map"}</button>
      </div>
    </dialog>
    """
  end

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :show_past, :boolean, default: false
  attr :now, DateTime, default: nil
  @doc "Lists meetups with an optional past-event toggle, independently of active map pins."
  @spec meetup_section(map()) :: Phoenix.LiveView.Rendered.t()
  def meetup_section(assigns) do
    assigns =
      assign(
        assigns,
        :visible,
        if(assigns.show_past,
          do: assigns.points,
          else: CATools.Maps.active_points(assigns.points, assigns.now || DateTime.utc_now())
        )
      )

    assigns =
      assign(
        assigns,
        :past_count,
        Enum.count(
          assigns.points,
          &CATools.Maps.meetup_ended?(&1, assigns.now || DateTime.utc_now())
        )
      )

    ~H"""
    <section id={@id} class="mt-9">
      <div class="flex flex-wrap items-center justify-between gap-3 mb-4">
        <h2 class="text-xl font-semibold">Meetups</h2>
        <button
          :if={@past_count > 0}
          phx-click="toggle_past"
          aria-pressed={to_string(@show_past)}
          class="atlas-button"
        >
          {if @show_past, do: "Hide past meetups", else: "Show past meetups (#{@past_count})"}
        </button>
      </div>
      <div :if={@visible == []} class="atlas-empty text-sm opacity-65">No upcoming meetups yet.</div>
      <div class="grid md:grid-cols-3 gap-4">
        <article :for={point <- @visible} class="atlas-card p-5">
          <.meetup_image image_url={point.cover_photo_url} title={point.title} />
          <.meetup_host name={point.host_name} avatar_url={point.host_avatar_url} />
          <span :if={CATools.Maps.meetup_ended?(point)} class="atlas-status inline-block mb-2">Finished</span>
          <h3 class="font-semibold">{point.title}</h3>
          <p class="text-sm opacity-65 mt-2">{point.group_name}</p>
          <p class="text-xs mt-2 opacity-60">{point.address}</p>
          <p :if={point.starts_at} class="text-xs mt-3">
            <.local_time
              id={"#{@id}-time-#{point.id}"}
              datetime={point.starts_at}
              ends_at={point.ends_at}
            />
          </p>
          <.link
            :if={point[:source_url]}
            href={point.source_url}
            target="_blank"
            rel="noopener noreferrer"
            class="text-xs underline mt-4 inline-block"
          >View on Campfire</.link>
        </article>
      </div>
    </section>
    """
  end

  attr :points, :list, required: true
  attr :retry_event, :string, default: nil
  @doc "Shows local image download progress and recorded failures for the map owner."
  @spec image_status(map()) :: Phoenix.LiveView.Rendered.t()
  def image_status(assigns) do
    assigns = assign(assigns, :images, CATools.Maps.ImageCache.summary(assigns.points))

    ~H"""
    <div :if={@images.total > 0} class="text-xs space-y-2" aria-label="Image download status">
      <p>Images: {@images.saved} saved · {@images.pending} pending · {@images.failed} failed</p>
      <p :for={error <- @images.errors} class="text-error" role="status">{error}</p>
      <button
        :if={@images.failed > 0 && @retry_event}
        phx-click={@retry_event}
        phx-disable-with="Queuing..."
        data-confirm="Retry failed image downloads? This makes another request to their image URLs. Saved images will be reused."
        class="atlas-button"
      >Retry failed images</button>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :datetime, DateTime, required: true
  attr :ends_at, DateTime, default: nil
  attr :class, :string, default: nil
  @doc "Renders a date and optional same-day time range in the viewer's browser time zone."
  @spec local_time(map()) :: Phoenix.LiveView.Rendered.t()
  def local_time(assigns) do
    ~H"""
    <time
      id={@id}
      datetime={DateTime.to_iso8601(@datetime)}
      data-ends-at={@ends_at && DateTime.to_iso8601(@ends_at)}
      phx-hook="LocalTime"
      class={@class}
    >
      {Calendar.strftime(@datetime, "%b %d, %Y, %H:%M")}{if @ends_at,
        do: "–" <> Calendar.strftime(@ends_at, "%H:%M")}
    </time>
    """
  end

  attr :image_url, :string, default: nil
  attr :title, :string, required: true
  @doc "Renders an optional meetup cover image without sending the page URL to its host."
  @spec meetup_image(map()) :: Phoenix.LiveView.Rendered.t()
  def meetup_image(assigns) do
    assigns = assign(assigns, :image_url, CATools.Maps.ImageURL.local(assigns.image_url))

    ~H"""
    <img
      :if={@image_url}
      src={@image_url}
      alt={@title}
      loading="lazy"
      referrerpolicy="no-referrer"
      class="atlas-meetup-image"
    />
    """
  end

  attr :name, :string, default: nil
  attr :avatar_url, :string, default: nil
  @doc "Displays the meetup creator's name and optional profile picture."
  @spec meetup_host(map()) :: Phoenix.LiveView.Rendered.t()
  def meetup_host(assigns) do
    assigns = assign(assigns, :avatar_url, CATools.Maps.ImageURL.local(assigns.avatar_url))

    ~H"""
    <div :if={@name || @avatar_url} class="atlas-meetup-host">
      <img :if={@avatar_url} src={@avatar_url} alt="" loading="lazy" referrerpolicy="no-referrer" />
      <span>Hosted by <strong>{@name || "Campfire host"}</strong></span>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :points, :list, required: true
  attr :now, DateTime, default: nil
  @doc "Renders a Leaflet map with escaped JSON and a stable canvas."
  @spec map_canvas(map()) :: Phoenix.LiveView.Rendered.t()
  def map_canvas(assigns) do
    assigns =
      assign(
        assigns,
        :points,
        CATools.Maps.active_points(assigns.points, assigns.now || DateTime.utc_now())
      )

    assigns =
      assign(
        assigns,
        :tile_url,
        Application.get_env(
          :ca_tools,
          :map_tile_url,
          "https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        )
      )

    ~H"""
    <div id={@id} phx-hook="AtlasMap" data-tile-url={@tile_url}>
      <div
        id={@id <> "-canvas"}
        phx-update="ignore"
        data-map-canvas
        class="atlas-map"
        role="region"
        aria-label="Map of meetup locations"
      >
      </div>
      <span hidden data-map-points>{Jason.encode!(@points)}</span>
    </div>
    """
  end
end
