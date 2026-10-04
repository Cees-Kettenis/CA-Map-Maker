defmodule CATools.Maps.CachedImage do
  @moduledoc "Records image download attempts, processing and expiry."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "cached_images" do
    field :content_type, :string
    field :status, :string, default: "downloading"
    field :error_code, :string
    field :error_message, :string
    field :http_status, :integer
    field :bytes, :integer
    field :processing_version, :integer
    field :redirect_url, :string
    field :attempted_at, :utc_datetime
  end
end
