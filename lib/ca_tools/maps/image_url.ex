defmodule CATools.Maps.ImageURL do
  @moduledoc "Validates external meetup images for map views and exports."

  @doc "Accepts only local cached image paths for rendering."
  @spec local(term()) :: String.t() | nil
  def local(value) do
    if is_binary(value) and Regex.match?(~r/\A\/media\/meetups\/[0-9a-f]{64}(\?v=[12])?\z/, value),
      do: value
  end

  @doc "Returns an HTTPS image URL without embedded credentials, or nil."
  @spec normalize(term()) :: String.t() | nil
  def normalize(value) do
    case value do
      value when is_binary(value) ->
        value = String.trim(value)

        case URI.parse(value) do
          %URI{scheme: "https", host: host, userinfo: nil, port: port}
          when is_binary(host) and host != "" and port in [nil, 443] ->
            value

          _ ->
            nil
        end

      _ ->
        nil
    end
  rescue
    ArgumentError -> nil
  end
end
