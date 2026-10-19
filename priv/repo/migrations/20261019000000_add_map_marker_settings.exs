defmodule CATools.Repo.Migrations.AddMapMarkerSettings do
  use Ecto.Migration

  def change do
    alter table(:maps) do
      add :marker_style, :string, null: false, default: "plain"
      add :marker_color, :string, null: false, default: "#2563eb"
    end

    create constraint(:maps, :valid_marker_style,
             check: "marker_style IN ('plain', 'community', 'meetup')"
           )

    create constraint(:maps, :valid_marker_color, check: "marker_color ~ '^#[0-9a-fA-F]{6}$'")
  end
end
