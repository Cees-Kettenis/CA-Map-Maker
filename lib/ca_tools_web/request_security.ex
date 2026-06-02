defmodule CAToolsWeb.RequestSecurity do
  @moduledoc """
  Shared helpers for request identification and rate-limit enforcement.
  """

  alias CATools.RateLimiter

  @type rate_limit_name :: CATools.RateLimiter.limit_name()
  @type rate_limit_result :: :ok | {:error, non_neg_integer()}

  @doc """
  Returns the remote IP address for a plug connection as a string.
  """
  @spec client_ip(Plug.Conn.t()) :: String.t()
  def client_ip(conn) do
    conn.remote_ip
    |> :inet.ntoa()
    |> to_string()
  end

  @doc """
  Returns the LiveView client IP address when available.
  """
  @spec live_client_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def live_client_ip(socket) do
    case Phoenix.LiveView.get_connect_info(socket, :peer_data) do
      %{address: address} -> address |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  @doc """
  Returns a normalized email identifier for rate limiting.
  """
  @spec normalize_email_identifier(String.t() | term()) :: String.t()
  def normalize_email_identifier(email) do
    case email do
      value when is_binary(value) -> value |> String.trim() |> String.downcase()
      _ -> "unknown"
    end
  end

  @doc """
  Checks a list of rate limits and returns the longest retry window on denial.
  """
  @spec check_limits([{rate_limit_name(), String.t()}]) :: rate_limit_result()
  def check_limits(limits) when is_list(limits) do
    Enum.reduce_while(limits, :ok, fn {limit_name, identifier}, :ok ->
      case RateLimiter.check(limit_name, identifier) do
        :ok -> {:cont, :ok}
        {:error, retry_after_seconds} -> {:halt, {:error, retry_after_seconds}}
      end
    end)
  end
end
