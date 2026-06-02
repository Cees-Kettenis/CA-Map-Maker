defmodule CATools.RateLimiter do
  @moduledoc """
  Application-local rate limiter backed by Hammer ETS buckets.
  """

  use Hammer, backend: :ets

  @type limit_name ::
          :campfire_credentials_delete
          | :campfire_credentials_save
          | :campfire_credentials_validate
          | :login_magic_email
          | :login_magic_ip
          | :login_password_email
          | :login_password_ip
          | :registration_email
          | :registration_ip

  @type result :: :ok | {:error, non_neg_integer()}

  @doc """
  Checks the configured rate limit for the given identifier.
  """
  @spec check(limit_name(), String.t()) :: result()
  def check(limit_name, identifier) when is_atom(limit_name) and is_binary(identifier) do
    %{scale_ms: scale_ms, limit: limit} = configured_limit(limit_name)

    case hit({limit_name, identifier}, scale_ms, limit) do
      {:allow, _count} -> :ok
      {:deny, retry_after_ms} -> {:error, ceil(retry_after_ms / 1_000)}
    end
  end

  @doc """
  Clears the in-memory rate-limit buckets.
  """
  @spec reset() :: :ok
  def reset do
    case :ets.whereis(__MODULE__) do
      :undefined -> :ok
      table -> :ets.delete_all_objects(table)
    end

    :ok
  end

  defp configured_limit(limit_name) do
    Application.fetch_env!(:ca_tools, __MODULE__)
    |> Keyword.fetch!(:limits)
    |> Map.fetch!(limit_name)
  end
end
