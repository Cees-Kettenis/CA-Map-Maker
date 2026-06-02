defmodule CATools.Campfire.LinkResolver do
  @moduledoc """
  Normalizes and resolves supported Campfire source links.
  """

  @allowed_hosts ["cmpf.re", "campfire.nianticlabs.com"]
  @default_timeout 15_000
  @default_redirect_limit 5

  @type resource_type() :: :meetup | :event

  @type resolved_source() :: %{
          required(:resolved_url) => String.t(),
          required(:campfire_id) => String.t(),
          required(:resource_type) => resource_type()
        }

  @type error_details() :: %{
          required(:code) => String.t(),
          required(:message) => String.t()
        }

  @doc """
  Returns the supported Campfire hosts.
  """
  @spec allowed_hosts() :: [String.t()]
  def allowed_hosts do
    @allowed_hosts
  end

  @doc """
  Normalizes a single Campfire source URL and validates its host and scheme.
  """
  @spec normalize_source_url(term()) :: {:ok, String.t()} | {:error, String.t()}
  def normalize_source_url(url) do
    case url do
      value when is_binary(value) ->
        case URI.parse(value) do
          %URI{scheme: scheme, host: host} = uri
          when scheme in ["http", "https"] and is_binary(host) ->
            normalized_scheme = String.downcase(scheme)
            normalized_host = String.downcase(host)

            cond do
              uri.userinfo != nil ->
                {:error, "must not include embedded credentials."}

              uri.port not in [nil, default_port(normalized_scheme)] ->
                {:error, "must not include a custom port."}

              normalized_host not in @allowed_hosts ->
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

      _ ->
        {:error, "must be a valid http or https URL."}
    end
  end

  @doc """
  Resolves a supported Campfire link, follows bounded redirects, and extracts
  the Campfire meetup or event identifier from the final URL.
  """
  @spec resolve_source_url(term(), keyword()) ::
          {:ok, resolved_source()} | {:error, error_details()}
  def resolve_source_url(url, opts \\ []) do
    with {:ok, normalized_url} <- normalize_source_url(url),
         {:ok, resolved_url} <- follow_redirects(normalized_url, redirect_limit(opts), opts),
         {:ok, extracted} <- extract_resource_from_url(resolved_url) do
      {:ok, Map.put(extracted, :resolved_url, resolved_url)}
    else
      {:error, %{} = error_details} -> {:error, error_details}
      {:error, message} -> {:error, %{code: "invalid_url", message: message}}
    end
  end

  @doc """
  Extracts the Campfire meetup or event identifier from a resolved URL.
  """
  @spec extract_resource_from_url(String.t()) ::
          {:ok,
           %{required(:campfire_id) => String.t(), required(:resource_type) => resource_type()}}
          | {:error, error_details()}
  def extract_resource_from_url(url) do
    with {:ok, normalized_url} <- normalize_source_url(url),
         %URI{host: "campfire.nianticlabs.com", path: path} <- URI.parse(normalized_url),
         path when is_binary(path) <- path do
      case path |> String.trim("/") |> String.split("/", trim: true) do
        ["discover", "meetups", campfire_id | _rest] when campfire_id != "" ->
          {:ok, %{campfire_id: campfire_id, resource_type: :meetup}}

        ["discover", "events", campfire_id | _rest] when campfire_id != "" ->
          {:ok, %{campfire_id: campfire_id, resource_type: :event}}

        _ ->
          {:error,
           %{
             code: "unsupported_path",
             message:
               "Resolved Campfire URL must point to /discover/meetups/:id or /discover/events/:id."
           }}
      end
    else
      {:error, message} ->
        {:error, %{code: "invalid_url", message: message}}

      _ ->
        {:error,
         %{
           code: "unsupported_path",
           message: "Resolved link must point to Campfire discover pages."
         }}
    end
  end

  defp follow_redirects(url, remaining_redirects, opts) do
    case ensure_public_destination(url) do
      :ok ->
        request =
          [
            method: :get,
            url: url,
            redirect: false,
            receive_timeout: timeout(opts),
            retry: false
          ] ++ request_options(opts)

        case Req.request(request) do
          {:ok, %Req.Response{status: status, headers: headers}}
          when status in [301, 302, 303, 307, 308] ->
            case {remaining_redirects, location_header(headers), URI.parse(url)} do
              {0, _location, _current_uri} ->
                {:error,
                 %{
                   code: "redirect_limit_exceeded",
                   message: "Campfire link exceeded the maximum redirect limit."
                 }}

              {_count, nil, _current_uri} ->
                {:error,
                 %{
                   code: "missing_location",
                   message: "Campfire redirect response did not include a location header."
                 }}

              {_count, location, %URI{} = current_uri} ->
                next_url =
                  current_uri
                  |> URI.merge(location)
                  |> URI.to_string()

                with {:ok, normalized_next_url} <- normalize_source_url(next_url) do
                  follow_redirects(normalized_next_url, remaining_redirects - 1, opts)
                else
                  {:error, message} -> {:error, %{code: "invalid_redirect", message: message}}
                end
            end

          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            {:ok, url}

          {:ok, %Req.Response{status: 404}} ->
            {:error, %{code: "not_found", message: "Campfire link could not be found."}}

          {:ok, %Req.Response{status: status}} ->
            {:error,
             %{
               code: "unexpected_status",
               message: "Campfire link returned unexpected HTTP status #{status}."
             }}

          {:error, %Req.TransportError{reason: :timeout}} ->
            {:error, %{code: "timeout", message: "Campfire link resolution timed out."}}

          {:error, exception} ->
            {:error, %{code: "network_error", message: Exception.message(exception)}}
        end

      {:error, error_details} ->
        {:error, error_details}
    end
  end

  defp ensure_public_destination(url) do
    host = URI.parse(url).host || ""

    case resolve_host_addresses(host) do
      {:ok, addresses} ->
        case Enum.all?(addresses, &public_ip_address?/1) do
          true ->
            :ok

          false ->
            {:error,
             %{
               code: "ssrf_blocked",
               message:
                 "Campfire link resolved to a private or otherwise blocked network address."
             }}
        end

      {:error, reason} ->
        {:error,
         %{code: "dns_lookup_failed", message: "Could not resolve #{host}: #{inspect(reason)}."}}
    end
  end

  defp resolve_host_addresses(host) do
    ipv4_addresses =
      case :inet.getaddrs(String.to_charlist(host), :inet) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end

    ipv6_addresses =
      case :inet.getaddrs(String.to_charlist(host), :inet6) do
        {:ok, addresses} -> addresses
        {:error, _reason} -> []
      end

    case ipv4_addresses ++ ipv6_addresses do
      [] -> {:error, :nxdomain}
      addresses -> {:ok, addresses}
    end
  end

  defp public_ip_address?({127, _, _, _}), do: false
  defp public_ip_address?({10, _, _, _}), do: false
  defp public_ip_address?({0, _, _, _}), do: false
  defp public_ip_address?({169, 254, _, _}), do: false
  defp public_ip_address?({172, second, _, _}) when second in 16..31, do: false
  defp public_ip_address?({192, 168, _, _}), do: false
  defp public_ip_address?({192, 0, 0, _}), do: false
  defp public_ip_address?({198, 18, _, _}), do: false
  defp public_ip_address?({198, 19, _, _}), do: false
  defp public_ip_address?({first, _, _, _}) when first in 224..239, do: false
  defp public_ip_address?({_, _, _, _}), do: true
  defp public_ip_address?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip_address?({65152, _, _, _, _, _, _, _}), do: false
  defp public_ip_address?({64512, _, _, _, _, _, _, _}), do: false
  defp public_ip_address?({65024, _, _, _, _, _, _, _}), do: false
  defp public_ip_address?({65280, _, _, _, _, _, _, _}), do: false
  defp public_ip_address?({65535, _, _, _, _, _, _, _}), do: false
  defp public_ip_address?({_, _, _, _, _, _, _, _}), do: true

  defp request_options(opts) do
    Keyword.get(
      opts,
      :request_options,
      Application.get_env(:ca_tools, __MODULE__, [])[:request_options] || []
    )
  end

  defp timeout(opts) do
    Keyword.get(
      opts,
      :timeout,
      Application.get_env(:ca_tools, __MODULE__, [])[:timeout] || @default_timeout
    )
  end

  defp redirect_limit(opts) do
    Keyword.get(
      opts,
      :redirect_limit,
      Application.get_env(:ca_tools, __MODULE__, [])[:redirect_limit] || @default_redirect_limit
    )
  end

  defp location_header(headers) do
    Enum.find_value(headers, fn
      {"location", [location | _rest]} when is_binary(location) -> location
      {"location", location} when is_binary(location) -> location
      {"Location", [location | _rest]} when is_binary(location) -> location
      {"Location", location} when is_binary(location) -> location
      _ -> nil
    end)
  end

  defp default_port("http"), do: 80
  defp default_port("https"), do: 443
end
