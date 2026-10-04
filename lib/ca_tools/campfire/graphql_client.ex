defmodule CATools.Campfire.GraphQLClient do
  @moduledoc """
  Fetches Campfire resource data through the authenticated user's Campfire token.
  """

  alias CATools.Accounts
  alias CATools.Accounts.User
  alias CATools.Campfire.LinkResolver

  @default_endpoint "https://niantic-social-api.nianticlabs.com/graphql"
  @default_timeout 20_000

  @resource_query """
  query CampfireMapSource($id: ID!) {
    event(id: $id) {
      id
      name
      details
      coverPhotoUrl
      eventTime
      eventEndTime
      address
      location
      creator {
        displayName
        username
        avatarUrl
      }
      club {
        id
        name
      }
    }
  }
  """

  @type normalized_resource() :: %{
          required(:campfire_id) => String.t(),
          required(:resource_type) => LinkResolver.resource_type(),
          required(:resource) => map()
        }

  @type error_details() :: %{
          required(:code) => String.t(),
          required(:message) => String.t()
        }

  @doc """
  Fetches a Campfire resource for the given user and resolved source link.
  """
  @spec fetch_resource(User.t(), LinkResolver.resolved_source(), keyword()) ::
          {:ok, normalized_resource()} | {:error, error_details()}
  def fetch_resource(user, resolved_source, opts \\ []) do
    with {:ok, credentials} <- Accounts.shared_campfire_credentials(user),
         {:ok, token} <- extract_token(credentials),
         {:ok, response} <- request_resource(token, resolved_source, opts),
         {:ok, resource} <- normalize_response_body(response.body, resolved_source, token) do
      {:ok, resource}
    else
      {:error, %{} = error_details} -> {:error, error_details}
      {:error, reason} when is_atom(reason) -> {:error, credentials_error(reason)}
    end
  end

  @doc """
  Returns the GraphQL query used to fetch Campfire resources.
  """
  @spec resource_query() :: String.t()
  def resource_query do
    @resource_query
  end

  @doc "Fetches one page of the club's active meetup feed, matching campfire-tools."
  @spec fetch_club_page(User.t(), String.t(), String.t() | nil, keyword()) ::
          {:ok, map()} | {:error, error_details()}
  def fetch_club_page(user, club_id, cursor \\ nil, opts \\ []) do
    query = """
    query ActiveEvents_Query($clubId: ID!, $first: Int!, $after: String) {
      club(id: $clubId) {
        id name avatarUrl
        activeFeed(first: $first, after: $after) {
          edges { node { ... on Event { id } } }
          pageInfo { hasNextPage endCursor }
        }
      }
    }
    """

    with {:ok, credentials} <- Accounts.shared_campfire_credentials(user),
         {:ok, token} <- extract_token(credentials),
         {:ok, response} <-
           request_graphql(
             token,
             %{
               operationName: "ActiveEvents_Query",
               query: query,
               variables: %{clubId: club_id, first: 100, after: cursor}
             },
             opts
           ) do
      case response.body do
        %{"errors" => [_ | _]} ->
          normalize_response_body(response.body, %{campfire_id: club_id}, token)

        %{
          "data" => %{
            "club" =>
              %{
                "id" => ^club_id,
                "name" => name,
                "activeFeed" => %{
                  "edges" => edges,
                  "pageInfo" => %{"hasNextPage" => more, "endCursor" => next}
                }
              } = club
          }
        }
        when is_binary(name) and is_list(edges) and is_boolean(more) ->
          ids =
            Enum.flat_map(edges, fn
              %{"node" => %{"id" => id}} when is_binary(id) and id != "" -> [id]
              _ -> []
            end)

          if more and (not is_binary(next) or next == "" or next == cursor) do
            {:error,
             %{code: "invalid_response", message: "Campfire returned an invalid page cursor."}}
          else
            {:ok,
             %{
               name: name,
               avatar_url: CATools.Maps.ImageURL.normalize(club["avatarUrl"]),
               event_ids: Enum.uniq(ids),
               next_cursor: if(more, do: next)
             }}
          end

        _ ->
          {:error,
           %{
             code: "missing_group",
             message: "Campfire did not return this group. Check access and the group link."
           }}
      end
    else
      {:error, %{} = details} -> {:error, details}
      {:error, reason} when is_atom(reason) -> {:error, credentials_error(reason)}
    end
  end

  defp extract_token(credentials) do
    case credentials do
      %{"campfire" => %{"token" => token}} when is_binary(token) and token != "" ->
        {:ok, token}

      nil ->
        {:error,
         %{code: "missing_credentials", message: "User has no saved Campfire credentials."}}

      _ ->
        {:error,
         %{code: "invalid_credentials", message: "Saved Campfire credentials are incomplete."}}
    end
  end

  defp request_resource(token, resolved_source, opts) do
    body = %{
      "operationName" => "CampfireMapSource",
      "query" => @resource_query,
      "variables" => %{"id" => resolved_source.campfire_id}
    }

    request_graphql(token, body, opts)
  end

  defp request_graphql(token, body, opts) do
    request =
      [
        method: :post,
        url: endpoint(opts),
        auth: {:bearer, token},
        headers: [{"accept", "application/json"}],
        json: body,
        receive_timeout: timeout(opts),
        retry: false,
        redirect: false
      ] ++ request_options(opts)

    case Req.request(request) do
      {:ok, %Req.Response{status: status} = response} when status in 200..299 ->
        {:ok, response}

      {:ok, %Req.Response{status: 401}} ->
        {:error, %{code: "unauthorized", message: "Campfire rejected the saved credentials."}}

      {:ok, %Req.Response{status: 403}} ->
        {:error,
         %{code: "forbidden", message: "Campfire denied access to the requested resource."}}

      {:ok, %Req.Response{status: 404}} ->
        {:error, %{code: "not_found", message: "Campfire resource could not be found."}}

      {:ok, %Req.Response{status: status}} ->
        {:error,
         %{
           code: "unexpected_status",
           message: "Campfire GraphQL request failed with HTTP status #{status}."
         }}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, %{code: "timeout", message: "Campfire GraphQL request timed out."}}

      {:error, _exception} ->
        {:error,
         %{code: "network_error", message: "Could not connect to Campfire. Try again later."}}
    end
  end

  defp normalize_response_body(body, resolved_source, token) do
    case body do
      %{"errors" => [%{} | _] = errors} ->
        {:error,
         %{
           code: "graphql_error",
           message:
             errors
             |> Enum.map_join("; ", &graphql_error_message/1)
             |> String.replace(token, "[REDACTED]")
         }}

      %{"data" => data} when is_map(data) ->
        case extract_resource_node(data, resolved_source) do
          %{} = resource ->
            {:ok,
             %{
               campfire_id: resolved_source.campfire_id,
               resource_type: resolved_source.resource_type,
               resource: resource
             }}

          nil ->
            {:error,
             %{
               code: "missing_resource",
               message: "Campfire GraphQL response did not include the requested resource."
             }}
        end

      _ ->
        {:error, %{code: "invalid_response", message: "Campfire GraphQL response was malformed."}}
    end
  end

  defp extract_resource_node(data, resolved_source) do
    case data do
      %{"event" => %{"id" => id} = event} when id == resolved_source.campfire_id ->
        event

      _ ->
        nil
    end
  end

  defp graphql_error_message(error) do
    case error do
      %{"message" => message} when is_binary(message) -> message
      _ -> "unknown GraphQL error"
    end
  end

  defp credentials_error(reason) do
    case reason do
      :decryption_failed ->
        %{
          code: "credentials_decryption_failed",
          message: "Saved Campfire credentials could not be decrypted."
        }

      :invalid_payload ->
        %{code: "invalid_credentials", message: "Saved Campfire credentials are invalid."}
    end
  end

  defp endpoint(opts) do
    Keyword.get(
      opts,
      :endpoint,
      Application.get_env(:ca_tools, __MODULE__, [])[:endpoint] || @default_endpoint
    )
  end

  defp timeout(opts) do
    Keyword.get(
      opts,
      :timeout,
      Application.get_env(:ca_tools, __MODULE__, [])[:timeout] || @default_timeout
    )
  end

  defp request_options(opts) do
    Keyword.get(
      opts,
      :request_options,
      Application.get_env(:ca_tools, __MODULE__, [])[:request_options] || []
    )
  end
end
