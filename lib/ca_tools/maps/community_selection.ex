defmodule CATools.Maps.CommunitySelection do
  @moduledoc "Links a date-based map to the communities it follows."
  use Ecto.Schema

  schema "map_communities" do
    belongs_to :map, CATools.Maps.UserMap
    belongs_to :community, CATools.Communities.Community
  end
end
