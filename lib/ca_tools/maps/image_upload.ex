defmodule CATools.Maps.ImageUpload do
  @moduledoc "Tracks uploads even before they are attached to a map."
  use Ecto.Schema
  @primary_key false
  schema "image_uploads" do
    field :user_id, :id, primary_key: true
    field :image_id, :string, primary_key: true
  end
end
