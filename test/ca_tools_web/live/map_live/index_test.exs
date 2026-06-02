defmodule CAToolsWeb.MapLive.IndexTest do
  use CAToolsWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import CATools.AccountsFixtures
  import CATools.MapsFixtures

  describe "dashboard" do
    test "redirects if the user is not logged in", %{conn: conn} do
      assert {:error, redirect} = live(conn, ~p"/dashboard/maps")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/auth/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "renders only the current user's maps", %{conn: conn} do
      user = user_fixture()
      other_user = user_fixture()

      map_fixture(user_scope_fixture(user), %{"name" => "My Map"})
      map_fixture(user_scope_fixture(other_user), %{"name" => "Other Map"})

      {:ok, _lv, html} =
        conn
        |> log_in_user(user)
        |> live(~p"/dashboard/maps")

      assert html =~ "Map Dashboard"
      assert html =~ "My Map"
      refute html =~ "Other Map"
    end

    test "creates a map from the dashboard form", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/dashboard/maps")

      html =
        lv
        |> form("#map_form", %{
          "map" => %{
            "description" => "Imported from Campfire",
            "name" => "Bay Area Map",
            "source_urls_input" =>
              "https://cmpf.re/abc123\nhttps://campfire.nianticlabs.com/discover/meetups/xyz987",
            "visibility" => "private"
          }
        })
        |> render_submit()

      assert html =~ "Map created. Campfire links have been queued for import."
      assert html =~ "Bay Area Map"
      assert html =~ ">2<"
    end

    test "shows validation errors for unsupported links", %{conn: conn} do
      user = user_fixture()

      {:ok, lv, _html} =
        conn
        |> log_in_user(user)
        |> live(~p"/dashboard/maps")

      result =
        lv
        |> element("#map_form")
        |> render_change(%{
          "map" => %{
            "name" => "Broken Map",
            "source_urls_input" => "https://example.com/nope",
            "visibility" => "private"
          }
        })

      assert result =~ "unsupported host example.com"
    end
  end
end
