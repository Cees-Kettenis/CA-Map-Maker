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
        if connected?(socket), do: Maps.subscribe(map.user_id)

        {:ok,
         socket
         |> allow_upload(:map_image,
           accept: ~w(.png .jpg .jpeg .webp .gif),
           max_entries: 1,
           max_file_size: 5_000_000
         )
         |> assign(
           map: map,
           points: Maps.point_data(map, true),
           page_title: map.name,
           editing?: false,
           show_progress?: false,
           show_past?: false,
           view_time: DateTime.utc_now(),
           expiry_timer: if(connected?(socket), do: Maps.schedule_expiry(map.points)),
           linked_communities:
             CATools.MeetupMaps.communities(socket.assigns.current_scope, map.id),
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
        <.map_identity map={@map} />
        <div class="flex flex-wrap gap-2">
          <button
            phx-click={JS.dispatch("atlas:open", to: "#delete-map-dialog")}
            class="atlas-button atlas-button-danger"
          ><.icon name="hero-trash" class="size-4" /> Delete map</button>
          <button phx-click="edit" class="atlas-button"><.icon
            name="hero-pencil-square"
            class="size-4"
          /> Edit map</button><.link
            href={~p"/dashboard/maps/#{@map.id}/export.kml"}
            download="pogo-meetups-map.kml"
            class="atlas-button"
          ><.icon name="hero-arrow-down-tray" class="size-4" /> Export KML</.link>
          <button
            phx-click="toggle_progress"
            aria-expanded={to_string(@show_progress?)}
            aria-controls="map-import-progress"
            class="atlas-button"
          ><.icon name="hero-arrow-path" class="size-4" /> {if @show_progress?,
            do: "Hide updates",
            else: "Updates"}</button>
        </div>
      </div>
      <section :if={@editing?} class="atlas-card p-6 mb-7">
        <.form
          for={@form}
          id="edit_map_form"
          phx-change="validate_edit"
          phx-submit="save"
          class="grid sm:grid-cols-2 gap-4"
        >
          <.input field={@form[:name]} label="Map name" required /><.input
            field={@form[:visibility]}
            type="select"
            label="Visibility"
            options={[{"Private", :private}, {"Public", :public}]}
          />
          <div class="sm:col-span-2">
            <.input field={@form[:description]} type="textarea" label="Description" />
          </div>
          <div :if={is_nil(@map.community)} class="sm:col-span-2 space-y-3">
            <label for={@uploads.map_image.ref} class="block text-sm opacity-65">Map image</label>
            <.live_file_input
              upload={@uploads.map_image}
              class="file-input file-input-bordered w-full"
            />
            <p class="text-xs opacity-60">Square PNG, JPEG, WebP or GIF, up to 5 MB.</p>
            <div :for={entry <- @uploads.map_image.entries} class="flex items-center gap-3">
              <.live_img_preview entry={entry} class="size-20 rounded-xl object-contain" />
              <button
                type="button"
                phx-click="cancel_image"
                phx-value-ref={entry.ref}
                class="atlas-button"
              >Remove selection</button>
              <p :for={error <- upload_errors(@uploads.map_image, entry)} class="text-sm text-error">
                {case error do
                  :too_large -> "Choose an image smaller than 5 MB."
                  :not_accepted -> "Choose a PNG, JPEG, WebP or GIF image."
                  _ -> "Could not upload this image."
                end}
              </p>
            </div>
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
        id="map-sharing"
        class="atlas-card p-4 mb-7 flex flex-wrap items-center gap-3"
      >
        <.icon name="hero-globe-alt" class="size-5" /><span class="text-sm font-semibold">Share map</span>
        <p class="text-sm opacity-70 w-full">
          {if @map.visibility == :public,
            do: "Anyone with this link can view this map without signing in. Only you can edit it.",
            else:
              "Enable a public link so anyone can view this map without signing in. Only you can edit it."}
        </p>
        <input
          :if={@map.visibility == :public}
          id="share_url"
          readonly
          aria-label="Public map link"
          value={url(~p"/maps/#{@map.public_slug}")}
          class="input input-sm flex-1 min-w-40"
        />
        <button
          :if={@map.visibility == :public}
          id="copy-share"
          phx-hook="CopyLink"
          data-target="#share_url"
          data-url={url(~p"/maps/#{@map.public_slug}")}
          class="atlas-button"
        >Copy public link</button>
        <.link
          :if={@map.visibility == :public}
          href={~p"/maps/#{@map.public_slug}"}
          target="_blank"
          class="text-xs underline"
        >Open public map</.link>
        <button phx-click="toggle_sharing" class="atlas-button">
          {if @map.visibility == :public, do: "Make private", else: "Make public"}
        </button>
      </section>
      <div class={["grid gap-6", @show_progress? && "xl:grid-cols-[1fr_300px]"]}>
        <section class="atlas-card">
          <.map_canvas id="owner-map" points={@points} now={@view_time} /><div class="px-5 py-4 flex justify-between text-xs">
            <span>{length(Maps.active_points(@points, @view_time))} meetup locations</span>
          </div>
        </section>
        <aside :if={@show_progress?} id="map-import-progress" class="atlas-card p-5 space-y-5">
          <.update_summary map={@map} />
        </aside>
      </div>
      <.meetup_section id="owner-meetups" points={@points} show_past={@show_past?} now={@view_time} />
      <.delete_confirmation
        id="delete-map-dialog"
        name={@map.name}
        event="delete"
        target_id={@map.id}
        community={not is_nil(@map.community)}
      />
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
      "toggle_sharing" ->
        visibility = if socket.assigns.map.visibility == :public, do: :private, else: :public

        case Maps.update_map(scope, id, %{visibility: visibility}) do
          {:ok, map} ->
            {:noreply,
             socket
             |> assign(map: map, form: to_form(Maps.change_existing_map(map), as: "map"))
             |> put_flash(
               :info,
               if(visibility == :public,
                 do: "Public link enabled.",
                 else: "Public link disabled."
               )
             )}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not update map sharing.")}
        end

      "update_now" ->
        Maps.request_update(scope, id)
        {:noreply, put_flash(socket, :info, "Update started.")}

      "toggle_progress" ->
        {:noreply, assign(socket, show_progress?: !socket.assigns.show_progress?)}

      "toggle_past" ->
        {:noreply, assign(socket, show_past?: !socket.assigns.show_past?)}

      "retry_images" ->
        case CATools.Maps.ImageCache.retry_failed(scope, id) do
          {:ok, count} ->
            {:noreply,
             put_flash(socket, :info, "#{count} failed image downloads queued for retry.")}

          _ ->
            {:noreply, put_flash(socket, :error, "Could not retry image downloads.")}
        end

      "edit" ->
        {:noreply, assign(socket, editing?: !socket.assigns.editing?)}

      "validate_edit" ->
        changeset = Maps.change_existing_map(socket.assigns.map, params["map"] || %{})
        {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}, as: "map"))}

      "cancel_image" ->
        {:noreply, cancel_upload(socket, :map_image, params["ref"])}

      "save" ->
        attrs = Map.delete(params["map"] || %{}, "image_id")
        changeset = Maps.change_existing_map(socket.assigns.map, attrs)

        if changeset.valid? do
          images =
            if is_nil(socket.assigns.map.community) do
              consume_uploaded_entries(socket, :map_image, fn %{path: path}, _entry ->
                {:ok,
                 CATools.Maps.ImageCache.store_upload(path, socket.assigns.current_scope.user.id)}
              end)
            else
              []
            end

          if Enum.any?(images, &match?({:error, _}, &1)) do
            {:noreply,
             put_flash(
               socket,
               :error,
               "Could not save the image. Choose a valid image and try again."
             )}
          else
            attrs =
              case images do
                [{:ok, image_id}] -> Map.put(attrs, "image_id", image_id)
                _ -> attrs
              end

            case Maps.update_map(scope, id, attrs) do
              {:ok, map} ->
                {:noreply,
                 socket
                 |> assign(
                   map: map,
                   editing?: false,
                   page_title: map.name,
                   form: to_form(Maps.change_existing_map(map), as: "map")
                 )
                 |> put_flash(:info, "Map updated.")}

              {:error, %Ecto.Changeset{} = changeset} ->
                {:noreply, assign(socket, form: to_form(changeset, as: "map"))}

              _ ->
                {:noreply, push_navigate(socket, to: ~p"/dashboard/maps")}
            end
          end
        else
          {:noreply, assign(socket, form: to_form(%{changeset | action: :validate}, as: "map"))}
        end

      "delete" ->
        Maps.delete_map(scope, id)

        {:noreply,
         socket |> put_flash(:info, "Map deleted.") |> push_navigate(to: ~p"/dashboard/maps")}
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
        {:noreply,
         assign(socket,
           map: map,
           points: Maps.point_data(map, true),
           view_time: DateTime.utc_now(),
           expiry_timer: Maps.schedule_expiry(map.points, socket.assigns.expiry_timer)
         )}
    end
  end
end
