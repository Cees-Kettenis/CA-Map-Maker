defmodule CATools.Campfire.ResponseCacheTest do
  use CATools.DataCase, async: false
  alias CATools.Campfire.ResponseCache

  test "concurrent cache misses on separate database connections fetch only once" do
    key = "concurrent-#{System.unique_integer([:positive])}"
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    body = %{"data" => %{"event" => %{"id" => "shared-event"}}}

    fetch = fn ->
      Agent.update(counter, &(&1 + 1))
      Process.sleep(50)
      {:ok, body}
    end

    try do
      tasks =
        for _ <- 1..12 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
              ResponseCache.fetch(key, 86_400, fetch, fn _ -> true end)
            end)
          end)
        end

      assert Enum.map(tasks, &Task.await(&1, 10_000)) == List.duplicate({:ok, body}, 12)
      assert Agent.get(counter, & &1) == 1
    after
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete_all(from c in ResponseCache, where: c.key == ^key)
      end)

      Agent.stop(counter)
    end
  end

  test "expired entries refresh once and failed responses are not retained" do
    key = "expiration"
    valid? = fn _ -> true end
    body = %{"data" => %{"event" => %{"id" => "shared-event"}}}

    assert {:error, %{code: "timeout"}} =
             ResponseCache.fetch(key, 86_400, fn -> {:error, %{code: "timeout"}} end, valid?)

    refute Repo.get(ResponseCache, key)
    assert {:ok, ^body} = ResponseCache.fetch(key, 86_400, fn -> {:ok, body} end, valid?)

    Repo.update_all(ResponseCache,
      set: [fetched_at: DateTime.add(DateTime.utc_now(:second), -61)]
    )

    assert {:ok, ^body} =
             ResponseCache.fetch(
               key,
               86_400,
               fn -> flunk("fresh data was fetched again") end,
               valid?
             )

    updated = put_in(body, ["data", "event", "name"], "Updated")
    assert {:ok, ^updated} = ResponseCache.fetch(key, 60, fn -> {:ok, updated} end, valid?)

    assert {:ok, ^updated} =
             ResponseCache.fetch(
               key,
               60,
               fn -> flunk("concurrent update was fetched twice") end,
               valid?
             )
  end
end
