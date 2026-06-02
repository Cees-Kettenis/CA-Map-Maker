defmodule CATools.Maps do
  @moduledoc """
  The Maps context.
  """

  import Ecto.Query, warn: false

  alias CATools.Accounts.Scope
  alias CATools.Maps.{MapSource, UserMap}
  alias CATools.Repo
  alias Ecto.Changeset

  @allowed_campfire_hosts ["cmpf.re", "campfire.nianticlabs.com"]

  @type source_url_error() :: String.t()
  @type source_url_result() :: {:ok, [String.t()]} | {:error, [source_url_error()]}

  @doc """
  Lists maps owned by the current scope's user.
  """
  @spec list_maps(Scope.t() | nil) :: [UserMap.t()]
  def list_maps(scope) do
    case scope do
      %Scope{user: %{id: user_id}} ->
        UserMap
        |> where([map], map.user_id == ^user_id)
        |> order_by([map], desc: map.inserted_at)
        |> preload([:sources])
        |> Repo.all()

      _ ->
        []
    end
  end

  @doc """
  Gets a single map owned by the current scope's user.
  """
  @spec get_map(Scope.t() | nil, term()) :: UserMap.t() | nil
  def get_map(scope, id) do
    case authorized_user_id(scope) do
      {:ok, user_id} ->
        UserMap
        |> where([map], map.id == ^id and map.user_id == ^user_id)
        |> preload([:sources, :points])
        |> Repo.one()

      :error ->
        nil
    end
  end

  @doc """
  Returns a changeset for creating a map owned by the current scope's user.
  """
  @spec change_map(Scope.t() | nil, map()) :: Changeset.t()
  def change_map(scope, attrs \\ %{}) do
    case authorized_user_id(scope) do
      {:ok, user_id} ->
        %UserMap{user_id: user_id}
        |> UserMap.creation_changeset(attrs)
        |> validate_source_urls()

      :error ->
        %UserMap{}
        |> UserMap.creation_changeset(attrs)
        |> Changeset.add_error(:base, "You must log in to manage maps.")
    end
  end

  @doc """
  Creates a map and its source URL records for the current scope's user.
  """
  @spec create_map(Scope.t() | nil, map()) ::
          {:ok, UserMap.t()} | {:error, Changeset.t()} | {:error, :unauthorized}
  def create_map(scope, attrs) do
    case authorized_user_id(scope) do
      {:ok, user_id} ->
        changeset =
          %UserMap{user_id: user_id}
          |> UserMap.creation_changeset(attrs)
          |> validate_source_urls()

        case changeset.valid? do
          true ->
            case normalize_source_urls(Changeset.get_field(changeset, :source_urls_input)) do
              {:ok, normalized_urls} ->
                create_map_with_sources(changeset, normalized_urls)

              {:error, messages} ->
                {:error,
                 Enum.reduce(messages, changeset, fn message, current_changeset ->
                   Changeset.add_error(current_changeset, :source_urls_input, message)
                 end)}
            end

          false ->
            {:error, changeset}
        end

      :error ->
        {:error, :unauthorized}
    end
  end

  @doc """
  Normalizes a multi-line Campfire link input into unique, supported source URLs.
  """
  @spec normalize_source_urls(term()) :: source_url_result()
  def normalize_source_urls(raw_input) do
    case raw_input do
      value when is_binary(value) ->
        lines =
          value
          |> String.split(~r/\r\n|\n|\r/, trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))

        validate_source_url_lines(lines)

      _ ->
        {:error, ["Enter at least one Campfire link."]}
    end
  end

  defp validate_source_urls(changeset) do
    input = Changeset.get_field(changeset, :source_urls_input)

    case normalize_source_urls(input) do
      {:ok, _normalized_urls} ->
        changeset

      {:error, messages} ->
        Enum.reduce(messages, changeset, fn message, current_changeset ->
          Changeset.add_error(current_changeset, :source_urls_input, message)
        end)
    end
  end

  defp validate_source_url_lines(lines) do
    case lines do
      [] ->
        {:error, ["Enter at least one Campfire link."]}

      _ ->
        {normalized_urls, errors, _seen_urls} =
          lines
          |> Enum.with_index(1)
          |> Enum.reduce({[], [], MapSet.new()}, fn {line, line_number},
                                                    {urls, messages, seen_urls} ->
            case normalize_source_url(line) do
              {:ok, normalized_url} ->
                case MapSet.member?(seen_urls, normalized_url) do
                  true ->
                    {urls, messages, seen_urls}

                  false ->
                    {urls ++ [normalized_url], messages, MapSet.put(seen_urls, normalized_url)}
                end

              {:error, message} ->
                {urls, messages ++ ["Line #{line_number}: #{message}"], seen_urls}
            end
          end)

        case {length(normalized_urls), errors} do
          {0, []} ->
            {:error, ["Enter at least one Campfire link."]}

          {_count, [_ | _] = messages} ->
            {:error, messages}

          {_count, []} ->
            {:ok, normalized_urls}
        end
    end
  end

  defp normalize_source_url(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} = uri
      when scheme in ["http", "https"] and is_binary(host) ->
        normalized_scheme = String.downcase(scheme)
        normalized_host = String.downcase(host)

        cond do
          uri.userinfo != nil ->
            {:error, "must not include embedded credentials."}

          uri.port not in [nil, default_port(normalized_scheme)] ->
            {:error, "must not include a custom port."}

          normalized_host not in @allowed_campfire_hosts ->
            {:error,
             "unsupported host #{host}. Only cmpf.re and campfire.nianticlabs.com are allowed."}

          true ->
            normalized_uri = %URI{
              uri
              | scheme: normalized_scheme,
                host: normalized_host,
                port: nil,
                fragment: nil
            }

            {:ok, URI.to_string(normalized_uri)}
        end

      _ ->
        {:error, "must be a valid http or https URL."}
    end
  end

  defp create_map_with_sources(changeset, normalized_urls) do
    slug = maybe_generate_public_slug(Changeset.get_field(changeset, :visibility))
    now = DateTime.utc_now(:second)

    final_changeset =
      changeset
      |> Changeset.put_change(:public_slug, slug)
      |> Changeset.put_change(:sources_count, length(normalized_urls))
      |> Changeset.put_change(:points_count, 0)

    source_entries =
      Enum.map(normalized_urls, fn url ->
        %{
          original_url: url,
          status: :pending,
          inserted_at: now,
          updated_at: now
        }
      end)

    Repo.transact(fn ->
      case Repo.insert(final_changeset) do
        {:ok, map} ->
          inserted_sources =
            Enum.map(source_entries, fn entry ->
              Map.put(entry, :map_id, map.id)
            end)

          case Repo.insert_all(MapSource, inserted_sources) do
            {count, _} when count == length(inserted_sources) ->
              {:ok, Repo.preload(map, :sources)}

            other ->
              Repo.rollback({:sources, other})
          end

        {:error, %Changeset{} = insert_changeset} ->
          Repo.rollback({:map, insert_changeset})
      end
    end)
    |> case do
      {:ok, map} ->
        {:ok, map}

      {:error, {:map, %Changeset{} = insert_changeset}} ->
        {:error, insert_changeset}

      {:error, {:sources, _reason}} ->
        {:error,
         Changeset.add_error(changeset, :source_urls_input, "Could not save map sources.")}
    end
  end

  defp maybe_generate_public_slug(visibility) do
    case visibility do
      :public -> Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      _ -> nil
    end
  end

  defp authorized_user_id(scope) do
    case scope do
      %Scope{user: %{id: user_id}} -> {:ok, user_id}
      _ -> :error
    end
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
end
