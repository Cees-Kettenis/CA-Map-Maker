defmodule CATools.Campfire.ClubResolver do
  @moduledoc "Resolves group links and invitation deep links using campfire-tools' club ID format."
  alias CATools.Campfire.LinkResolver

  @doc "Validates a group or invitation link without making a network request."
  @spec validate_url(term()) :: {:ok, String.t()} | {:error, String.t()}
  def validate_url(value) do
    url = if is_binary(value), do: String.trim(value), else: value

    with {:ok, normalized} <-
           LinkResolver.normalize_source_url(url, additional_hosts: ["campfire.onelink.me"]) do
      uri = URI.parse(normalized)

      if uri.host in ["cmpf.re", "campfire.onelink.me"] or match?({:ok, _}, club_id(normalized)) do
        {:ok, normalized}
      else
        {:error, "Enter a Campfire group or invitation link."}
      end
    end
  end

  @doc "Resolves short invitations and extracts their club ID."
  @spec resolve(term(), keyword()) :: {:ok, String.t()} | {:error, map()}
  def resolve(url, opts \\ []) do
    case club_id(url) do
      {:ok, id} ->
        {:ok, id}

      _ ->
        opts = Keyword.put(opts, :additional_hosts, ["campfire.onelink.me"])
        with {:ok, resolved} <- LinkResolver.resolve_url(url, opts), do: club_id(resolved)
    end
  end

  @doc "Extracts direct group IDs or the base64 deep_link_sub1 invitation payload."
  @spec club_id(term()) :: {:ok, String.t()} | {:error, map()}
  def club_id(url) do
    with {:ok, normalized} <-
           LinkResolver.normalize_source_url(url, additional_hosts: ["campfire.onelink.me"]) do
      uri = URI.parse(normalized)
      params = URI.decode_query(uri.query || "")

      case {uri.host, String.split(uri.path || "", "/", trim: true), params} do
        {"campfire.nianticlabs.com", ["discover", kind, id], _}
        when kind in ["club", "clubs", "group", "groups"] ->
          {:ok, id}

        {_, _, %{"deep_link_sub1" => payload}} ->
          with {:ok, decoded} <- Base.decode64(payload, padding: false),
               %{"r" => "clubs", "c" => id} when id != "" <- URI.decode_query(decoded) do
            {:ok, id}
          else
            _ ->
              {:error,
               %{
                 code: "invalid_group",
                 message: "The invitation does not contain a valid Campfire group."
               }}
          end

        _ ->
          {:error,
           %{code: "invalid_group", message: "Enter a Campfire group or invitation link."}}
      end
    else
      {:error, message} -> {:error, %{code: "invalid_group", message: message}}
    end
  rescue
    ArgumentError -> {:error, %{code: "invalid_group", message: "The group link is malformed."}}
  end
end
