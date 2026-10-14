defmodule CATools.Campfire.TokenExpiryReminderJob do
  @moduledoc "Sends one administrator reminder twelve hours before the current shared token expires."
  use Oban.Worker, queue: :maintenance, max_attempts: 5

  import Ecto.Query
  alias CATools.Accounts.{User, UserNotifier}
  alias CATools.Repo

  @doc "Cancels pending reminders when an administrator replaces or deletes their shared token."
  @spec cancel(pos_integer()) :: :ok
  def cancel(user_id) do
    {:ok, _count} =
      Oban.cancel_all_jobs(
        from j in Oban.Job,
          where:
            j.worker == ^Oban.Worker.to_string(__MODULE__) and j.args["user_id"] == ^user_id and
              j.state in ["available", "scheduled", "retryable"]
      )

    :ok
  end

  @impl Oban.Worker
  @doc "Checks the current token and administrator email at delivery time, skipping obsolete or already sent reminders."
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()} | {:snooze, pos_integer()}
  def perform(job) do
    %{"user_id" => user_id, "credential_version" => version} = job.args

    result =
      Repo.transact(fn ->
        user = Repo.one(from u in User, where: u.id == ^user_id and u.admin, lock: "FOR UPDATE")
        now = DateTime.utc_now(:second)

        case user do
          %User{
            encrypted_credentials: %{"iv" => ^version},
            campfire_token_expires_at: %DateTime{} = expiry,
            campfire_token_reminded_at: nil
          } ->
            reminder_at = DateTime.add(expiry, -12, :hour)

            if DateTime.compare(reminder_at, now) == :gt do
              {:ok, {:snooze, DateTime.diff(reminder_at, now)}}
            else
              with {:ok, _email} <-
                     UserNotifier.deliver_campfire_token_expiry(
                       user,
                       expiry,
                       CAToolsWeb.Endpoint.url() <> "/auth/users/settings"
                     ),
                   {:ok, _user} <-
                     user
                     |> Ecto.Changeset.change(campfire_token_reminded_at: now)
                     |> Repo.update() do
                {:ok, :ok}
              end
            end

          _ ->
            {:ok, :ok}
        end
      end)

    case result do
      {:ok, outcome} -> outcome
      {:error, reason} -> {:error, reason}
    end
  end
end
