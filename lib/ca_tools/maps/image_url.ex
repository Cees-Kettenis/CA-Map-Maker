defmodule CATools.Maps.ImageURL do
  @moduledoc "Validates external meetup images for map views and exports."

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
