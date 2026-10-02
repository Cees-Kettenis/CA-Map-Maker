defmodule CATools.Campfire.DataNormalizer do
  @moduledoc """
  Normalizes Campfire resource data into local map point attributes.
  """

  alias CATools.Campfire.GraphQLClient
  alias CATools.Campfire.LinkResolver

  @type map_point_attrs() :: %{
          required(:campfire_id) => String.t(),
          required(:group_name) => String.t() | nil,
          required(:title) => String.t(),
          required(:description) => String.t() | nil,
          required(:latitude) => float(),
          required(:longitude) => float(),
          required(:address) => String.t() | nil,
          required(:starts_at) => DateTime.t() | nil,
          required(:ends_at) => DateTime.t() | nil,
          required(:source_url) => String.t(),
          required(:payload_hash) => String.t()
        }

  @type error_details() :: %{
          required(:code) => String.t(),
          required(:message) => String.t()
        }

  @doc """
  Converts a Campfire GraphQL resource into map point attributes for persistence.
  """
  @spec normalize_map_point(GraphQLClient.normalized_resource(), LinkResolver.resolved_source()) ::
          {:ok, map_point_attrs()} | {:error, error_details()}
  def normalize_map_point(graphql_resource, resolved_source) do
    resource = graphql_resource.resource
    coordinates = coordinates(resource)
    title = resource["name"] || resource["title"]

    with {:ok, latitude, longitude} <- normalize_coordinates(coordinates),
         {:ok, normalized_title} <- normalize_title(title) do
      normalized_payload = %{
        campfire_id: graphql_resource.campfire_id,
        group_name: group_name(resource),
        title: normalized_title,
        description: string_or_nil(resource["details"] || resource["description"]),
        latitude: latitude,
        longitude: longitude,
        address: address(resource),
        starts_at:
          datetime_or_nil(resource["eventTime"] || resource["startTime"] || resource["startsAt"]),
        ends_at:
          datetime_or_nil(resource["eventEndTime"] || resource["endTime"] || resource["endsAt"]),
        source_url: resolved_source.resolved_url
      }

      {:ok, Map.put(normalized_payload, :payload_hash, payload_hash(normalized_payload))}
    end
  end

  defp coordinates(resource) do
    case resource["location"] do
      location when is_binary(location) ->
        # Campfire's scalar location uses longitude first, as in campfire-tools.
        values =
          case Jason.decode(location) do
            {:ok, values} when is_list(values) ->
              values

            _ ->
              location
              |> String.trim()
              |> String.trim("[")
              |> String.trim("]")
              |> String.trim("(")
              |> String.trim(")")
              |> String.split(",")
              |> Enum.map(&String.trim/1)
          end

        case values do
          [longitude, latitude | _] -> %{latitude: latitude, longitude: longitude}
          _ -> %{latitude: nil, longitude: nil}
        end

      location when is_map(location) ->
        %{
          latitude: location["latitude"] || location["lat"],
          longitude: location["longitude"] || location["lng"]
        }

      _ ->
        %{latitude: resource["latitude"], longitude: resource["longitude"]}
    end
  end

  defp normalize_coordinates(%{latitude: latitude, longitude: longitude}) do
    case {float_or_nil(latitude), float_or_nil(longitude)} do
      {latitude_value, longitude_value}
      when is_float(latitude_value) and is_float(longitude_value) and
             latitude_value >= -90 and latitude_value <= 90 and
             longitude_value >= -180 and longitude_value <= 180 ->
        {:ok, latitude_value, longitude_value}

      _ ->
        {:error,
         %{
           code: "missing_coordinates",
           message: "Campfire resource did not include usable latitude and longitude values."
         }}
    end
  end

  defp normalize_title(title) do
    case string_or_nil(title) do
      value when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:error, %{code: "missing_title", message: "Campfire resource did not include a title."}}
    end
  end

  defp group_name(resource) do
    case resource do
      %{"club" => %{"name" => name}} -> string_or_nil(name)
      %{"group" => %{"name" => name}} -> string_or_nil(name)
      %{"groupName" => name} -> string_or_nil(name)
      _ -> nil
    end
  end

  defp address(resource) do
    case resource do
      %{"address" => value} when is_binary(value) -> value
      %{"location" => %{"address" => value}} when is_binary(value) -> value
      _ -> nil
    end
  end

  defp payload_hash(payload) do
    payload
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp datetime_or_nil(value) do
    case value do
      %DateTime{} = datetime ->
        DateTime.truncate(datetime, :second)

      string when is_binary(string) ->
        case DateTime.from_iso8601(string) do
          {:ok, datetime, _offset} -> DateTime.truncate(datetime, :second)
          _ -> nil
        end

      unix when is_integer(unix) ->
        case DateTime.from_unix(unix) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp float_or_nil(value) do
    case value do
      number when is_float(number) ->
        number

      number when is_integer(number) ->
        number / 1

      string when is_binary(string) ->
        case Float.parse(string) do
          {parsed, ""} -> parsed
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp string_or_nil(value) do
    case value do
      string when is_binary(string) ->
        trimmed = String.trim(string)

        case trimmed do
          "" -> nil
          _ -> trimmed
        end

      _ ->
        nil
    end
  end
end
