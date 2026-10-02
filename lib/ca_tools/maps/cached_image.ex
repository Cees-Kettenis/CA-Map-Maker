defmodule CATools.Maps.CachedImage do
  @moduledoc "A permanent record of the single allowed download attempt for an image URL."
  use Ecto.Schema
  @primary_key {:id, :string, autogenerate: false}
  schema "cached_images" do
    field :content_type, :string
    field :status, :string, default: "downloading"
    field :error_code, :string
    field :error_message, :string
    field :http_status, :integer
    field :bytes, :integer
    field :redirect_url, :string
    field :attempted_at, :utc_datetime
  end
end
