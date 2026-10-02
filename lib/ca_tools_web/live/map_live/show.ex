defmodule CAToolsWeb.MapLive.Show do
  use CAToolsWeb, :live_view
  import CAToolsWeb.MapComponents
  alias CATools.Maps

  @impl true
  @doc false
  @spec mount(map(), map(), Phoenix.LiveView.Socket.t()) :: {:ok, Phoenix.LiveView.Socket.t()}
  def mount(%{"id" => id}, _session, socket) do
    case Maps.get_map(socket.assigns.current_scope, id) do
      nil ->
        raise CAToolsWeb.NotFoundError

      map ->
        if connected?(socket), do: Process.send_after(self(), :refresh, 3_000)

        {:ok,
         assign(socket,
           map: map,
           points: Maps.point_data(map, true),
           page_title: map.name,
           editing?: false,
           form: to_form(Maps.change_existing_map(map), as: "map")
         )}
    end
  end

  @impl true
  @doc false
  @spec render(map()) :: Phoenix.LiveView.Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.link navigate={~p"/dashboard/maps"} class="text-xs opacity-60 flex gap-2 items-center mb-7"><.icon
        name="hero-arrow-left"
        class="size-3"
      /> My Maps</.link>
      <div class="flex flex-wrap justify-between items-end gap-5 mb-7">
        <div>
          <h1 class="atlas-display text-3xl">
            {@map.name}
          </h1><p :if={@map.description not in [nil, ""]} class="mt-3 text-sm opacity-65">
            {@map.description}
          </p>
        </div>
        <div class="flex gap-2">
          <button phx-click="edit" class="atlas-button"><.icon
            name="hero-pencil-square"
            class="size-4"
          /> Edit map</button><.link
            href={~p"/dashboard/maps/#{@map.id}/export.kml"}
            class="atlas-button"
          ><.icon name="hero-arrow-down-tray" class="size-4" /> Export KML</.link>
        </div>
      </div>
      <section :if={@editing?} class="atlas-card p-6 mb-7">
        <.form for={@form} id="edit_map_form" phx-submit="save" class="grid sm:grid-cols-2 gap-4">
          <.input field={@form[:name]} label="Map name" required /><.input
            field={@form[:visibility]}
            type="select"
            label="Visibility"
            options={[{"Private", :private}, {"Public", :public}]}
          />
          <div class="sm:col-span-2">
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>
          <div class="flex gap-2">
            <.button variant="primary">Save changes</.button><button
              type="button"
              phx-click="edit"
              class="atlas-button"
            >Cancel</button>
          </div>
        </.form>
      </section>
      <section
        :if={@map.visibility == :public}
        class="atlas-card p-4 mb-7 flex flex-wrap items-center gap-3"
      >
        <.icon name="hero-globe-alt" class="size-5" /><span class="text-xs font-semibold">Ready to share</span>
        <input
          id="share_url"
          readonly
          aria-label="Public map link"
          value={url(~p"/maps/#{@map.public_slug}")}
          class="input input-sm flex-1 min-w-40"
        />
        <button
          id="copy-share"
          phx-hook="CopyLink"
          data-target="#share_url"
          data-url={url(~p"/maps/#{@map.public_slug}")}
          class="atlas-button"
        >Copy share link</button>
        <.link href={~p"/maps/#{@map.public_slug}"} target="_blank" class="text-xs underline">Open public map</.link>
      </section>
      <div class="grid xl:grid-cols-[1fr_300px] gap-6">
        <section class="atlas-card">
          <.map_canvas id="owner-map" points={@points} /><div class="px-5 py-4 flex justify-between text-xs">
            <span>{@map.points_count} meetup locations</span>
          </div>
        </section>
        <aside class="atlas-card p-5 space-y-5">
          <h2 class="text-xl font-semibold flex items-center gap-3">
            <span class="atlas-section-icon"><.icon name="hero-arrow-path" class="size-5" /></span>
            Import progress
          </h2>
          <div class="space-y-3 text-sm">
            <div class="flex justify-between">
              <span>Source links</span><span>{@map.sources_count}</span>
            </div><div class="flex justify-between">
              <span>On the map</span><span>{@map.points_count}</span>
            </div><div class="flex justify-between">
              <span>Failed</span><span>{Enum.count(@map.sources, &(&1.status == :failed))}</span>
            </div>
          </div>
          <p class="text-xs opacity-60">
            Up to 50 links per 10 minutes across your maps. You can leave this page while imports run.
          </p>
          <div :for={batch <- @map.batches} class="border-t border-base-300 pt-4 space-y-3">
            <div class="flex justify-between items-center">
              <span class="text-xs">Batch #{batch.id}</span><span
                class="atlas-status"
                data-status={batch.status}
              >{batch.status |> to_string() |> String.replace("_", " ")}</span>
            </div>
            <progress
              class="progress progress-primary h-1"
              value={batch.processed_count}
              max={max(batch.total_count, 1)}
              aria-label="Batch progress"
            ></progress>
            <p class="text-xs opacity-65">{batch.processed_count} of {batch.total_count} processed</p>
            <button
              :if={batch.status in [:queued, :processing]}
              phx-click="cancel_batch"
              phx-value-id={batch.id}
              class="text-xs underline"
              data-confirm="Stop the remaining imports in this batch?"
            >Cancel batch</button>
          </div>
          <div class="border-t border-base-300 pt-4 flex flex-col gap-2">
            <button phx-click="refresh" phx-value-mode="failed" class="atlas-button">Retry failed links</button><button
              phx-click="refresh"
              phx-value-mode="stale"
              class="atlas-button"
            >Refresh stale links</button><button
              phx-click="refresh"
              phx-value-mode="all"
              class="atlas-button"
            >Refresh all links</button>
          </div>
        </aside>
      </div>
      <section class="mt-9">
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-xl font-semibold">Meetups</h2>
        </div>
        <div :if={@points == []} class="atlas-empty text-sm opacity-65">
          No locations yet.
        </div>
        <div class="grid md:grid-cols-3 gap-4">
          <article :for={point <- @points} class="atlas-card p-5">
            <h3 class="font-semibold">{point.title}</h3><p class="text-sm opacity-65 mt-2">
              {point.group_name}
            </p><p class="text-xs mt-2 opacity-60">{point.address}</p><p
              :if={point.starts_at}
              class="text-xs mt-3"
            >
              {Calendar.strftime(point.starts_at, "%d %b %Y · %H:%M UTC")}
            </p><.link
              href={point.source_url}
              target="_blank"
              rel="noopener noreferrer"
              class="text-xs underline mt-4 inline-block"
            >View on Campfire</.link>
          </article>
        </div>
      </section>
      <section class="mt-9">
        <h2 class="text-xl font-semibold mb-4">Source links</h2><div class="atlas-card divide-y divide-base-300">
          <div
            :for={source <- @map.sources}
            class="px-5 py-4 flex flex-wrap gap-3 justify-between items-center"
          >
            <div class="min-w-0 flex-1">
              <a
                href={source.original_url}
                target="_blank"
                rel="noopener noreferrer"
                class="text-xs underline break-all"
              >{source.original_url}</a><p :if={source.error_message} class="text-xs text-error mt-1">
                {source.error_message}
              </p>
            </div><span class="atlas-status" data-status={source.status}>{source.status}</span>
          </div>
        </div>
      </section>
      <div class="mt-9 flex justify-end">
        <button
          phx-click="delete"
          data-confirm="Delete this map and all its locations? This cannot be undone."
          class="text-xs text-error underline"
        >Delete map</button>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  @doc false
  @spec handle_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event(event, params, socket) do
    scope = socket.assigns.current_scope
    id = socket.assigns.map.id

    case event do
      "edit" ->
        {:noreply, assign(socket, editing?: !socket.assigns.editing?)}

      "save" ->
        case Maps.update_map(scope, id, params["map"]) do
          {:ok, map} ->
            {:noreply,
             socket
             |> assign(map: map, editing?: false, page_title: map.name)
             |> put_flash(:info, "Map updated.")}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply, assign(socket, form: to_form(changeset, as: "map"))}

          _ ->
            {:noreply, push_navigate(socket, to: ~p"/dashboard/maps")}
        end

      "delete" ->
        Maps.delete_map(scope, id)

        {:noreply,
         socket |> put_flash(:info, "Map deleted.") |> push_navigate(to: ~p"/dashboard/maps")}

      "refresh" ->
        mode =
          case params["mode"] do
            "all" -> :all
            "stale" -> :stale
            _ -> :failed
          end

        case Maps.refresh_map(scope, id, mode) do
          {:ok, _} ->
            {:noreply, put_flash(socket, :info, "Links queued for refresh.")}

          {:error, :no_sources} ->
            {:noreply, put_flash(socket, :info, "No links need refreshing.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not refresh this map.")}
        end

      "cancel_batch" ->
        Maps.cancel_batch(scope, id, params["id"])
        {:noreply, put_flash(socket, :info, "Batch cancelled. Imported locations are kept.")}
    end
  end

  @impl true
  @doc false
  @spec handle_info(:refresh, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info(:refresh, socket) do
    case Maps.get_map(socket.assigns.current_scope, socket.assigns.map.id) do
      nil ->
        {:noreply, push_navigate(socket, to: ~p"/dashboard/maps")}

      map ->
        Process.send_after(self(), :refresh, 3_000)
        {:noreply, assign(socket, map: map, points: Maps.point_data(map, true))}
    end
  end
end
