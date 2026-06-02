defmodule CATools.MapsFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `CATools.Maps` context.
  """

  alias CATools.Maps

  def valid_map_attributes(attrs \\ %{}) do
    Enum.into(attrs, %{
      "description" => "Campfire meetup import",
      "name" => "Community Map",
      "source_urls_input" =>
        "https://cmpf.re/abc123\nhttps://campfire.nianticlabs.com/discover/meetups/xyz987",
      "visibility" => "private"
    })
  end

  def map_fixture(scope, attrs \\ %{}) do
    {:ok, map} =
      scope
      |> Maps.create_map(valid_map_attributes(attrs))

    map
  end
end
