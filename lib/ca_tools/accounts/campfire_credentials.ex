defmodule CATools.Accounts.CampfireCredentials do
  @moduledoc """
  Campfire credential normalization and encryption helpers.
  """

  @algorithm "AES-256-GCM"
  @version 1
  @aad_prefix "user_credentials:v1:"

  @type normalized_credentials :: %{
          required(String.t()) => %{required(String.t()) => String.t()}
        }

  @doc """
  Normalizes Campfire token input into the stored credentials structure.
  """
  @spec normalize(String.t() | term()) ::
          {:ok, normalized_credentials()} | {:error, String.t()}
  def normalize(input) do
    case input do
      value when is_binary(value) ->
        normalized_input = String.trim(value)

        cond do
          normalized_input == "" ->
            {:error, "can't be blank"}

          String.starts_with?(normalized_input, "{") ->
            normalize_json_headers(normalized_input)

          true ->
            normalize_plain_token(normalized_input)
        end

      _ ->
        {:error, "must be a string"}
    end
  end

  @doc """
  Encrypts normalized credentials for the given user.
  """
  @spec encrypt_user_credentials(pos_integer(), normalized_credentials()) :: map()
  def encrypt_user_credentials(user_id, credentials)
      when is_integer(user_id) and user_id > 0 and is_map(credentials) do
    plaintext = Jason.encode!(credentials)
    iv = :crypto.strong_rand_bytes(12)
    aad = additional_authenticated_data(user_id)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        credentials_master_key(),
        iv,
        plaintext,
        aad,
        true
      )

    %{
      "v" => @version,
      "alg" => @algorithm,
      "iv" => Base.encode64(iv),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext)
    }
  end

  @doc """
  Decrypts a stored encrypted credentials payload for the given user.
  """
  @spec decrypt_user_credentials(pos_integer(), map() | nil) ::
          {:ok, normalized_credentials() | nil} | {:error, atom()}
  def decrypt_user_credentials(_user_id, nil), do: {:ok, nil}

  def decrypt_user_credentials(user_id, encrypted_credentials)
      when is_integer(user_id) and user_id > 0 and is_map(encrypted_credentials) do
    with %{
           "v" => @version,
           "alg" => @algorithm,
           "iv" => encoded_iv,
           "tag" => encoded_tag,
           "ciphertext" => encoded_ciphertext
         } <- encrypted_credentials,
         {:ok, iv} <- Base.decode64(encoded_iv),
         {:ok, tag} <- Base.decode64(encoded_tag),
         {:ok, ciphertext} <- Base.decode64(encoded_ciphertext) do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             credentials_master_key(),
             iv,
             ciphertext,
             additional_authenticated_data(user_id),
             tag,
             false
           ) do
        plaintext when is_binary(plaintext) ->
          case Jason.decode(plaintext) do
            {:ok, decoded} -> {:ok, decoded}
            _ -> {:error, :invalid_payload}
          end

        :error ->
          {:error, :decryption_failed}
      end
    else
      :error -> {:error, :invalid_payload}
      _ -> {:error, :invalid_payload}
    end
  end

  def decrypt_user_credentials(_user_id, _encrypted_credentials), do: {:error, :invalid_payload}

  defp normalize_json_headers(json) do
    with {:ok, decoded} <- Jason.decode(json),
         authorization when is_binary(authorization) <- authorization_value(decoded) do
      normalize_plain_token(authorization)
    else
      {:error, _reason} -> {:error, "must be valid JSON if JSON is provided"}
      _ -> {:error, "must include an Authorization bearer token"}
    end
  end

  defp authorization_value(decoded) do
    case decoded do
      %{"Authorization" => value} when is_binary(value) -> value
      %{"authorization" => value} when is_binary(value) -> value
      %{"headers" => headers} when is_map(headers) -> authorization_value(headers)
      _ -> nil
    end
  end

  defp normalize_plain_token(input) do
    token =
      case Regex.run(~r/^(?:authorization\s*:\s*)?bearer\s+(.+)$/i, input,
             capture: :all_but_first
           ) do
        [captured_token] -> String.trim(captured_token)
        _ -> input
      end

    cond do
      token == "" ->
        {:error, "can't be blank"}

      String.match?(token, ~r/\s/) ->
        {:error, "must be a raw bearer token, bearer header, or headers JSON"}

      true ->
        {:ok, %{"campfire" => %{"token" => token, "token_type" => "bearer"}}}
    end
  end

  defp additional_authenticated_data(user_id) do
    @aad_prefix <> Integer.to_string(user_id)
  end

  defp credentials_master_key do
    encoded_key =
      Application.fetch_env!(:ca_tools, :runtime_secrets)
      |> Keyword.fetch!(:credentials_master_key_base64)

    case Base.decode64(encoded_key) do
      {:ok, key} when byte_size(key) == 32 -> key
      _ -> raise "CREDENTIALS_MASTER_KEY_BASE64 must decode to exactly 32 bytes"
    end
  end
end
