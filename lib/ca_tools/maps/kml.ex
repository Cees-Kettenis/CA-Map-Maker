defmodule CATools.Maps.KML do
  @moduledoc "Exports normalized map points as escaped KML 2.2."
  alias CATools.Maps.UserMap

  @doc "Builds a KML document. Source URLs are included only in owner exports."
  @spec generate(UserMap.t(), boolean()) :: String.t()
  def generate(map, owner? \\ false) do
    points =
      Enum.map(CATools.Maps.active_points(map.points), fn point ->
        description =
          [
            point.group_name,
            point.description,
            point.address,
            if(point.starts_at, do: DateTime.to_iso8601(point.starts_at)),
            if(owner?, do: point.source_url)
          ]
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")
          |> xml_text()

        {:Placemark,
         [
           {:name, xml_text(point.title)},
           {:description, description},
           {:Point, [{:coordinates, "#{point.longitude},#{point.latitude},0"}]}
         ]}
      end)

    XmlBuilder.document(
      {:kml, %{xmlns: "http://www.opengis.net/kml/2.2"},
       [
         {:Document,
          [{:name, xml_text(map.name)}, {:description, xml_text(map.description)}] ++ points}
       ]}
    )
    |> XmlBuilder.generate()
  end

  # XML 1.0 disallows control characters even when the serializer escapes markup.
  defp xml_text(value) do
    String.replace(
      value || "",
      ~r/[^\x{9}\x{A}\x{D}\x{20}-\x{D7FF}\x{E000}-\x{FFFD}\x{10000}-\x{10FFFF}]/u,
      ""
    )
  end
end
