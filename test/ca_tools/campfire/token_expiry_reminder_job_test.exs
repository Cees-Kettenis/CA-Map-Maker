defmodule CATools.Campfire.TokenExpiryReminderJobTest do
  use CATools.DataCase, async: false
  use Oban.Testing, repo: CATools.Repo

  import CATools.AccountsFixtures
  alias CATools.Accounts
  alias CATools.Accounts.{CampfireCredentials, User}
  alias CATools.Campfire.TokenExpiryReminderJob

  defmodule FailedMailer do
    use Swoosh.Adapter

    @doc false
    @spec deliver(Swoosh.Email.t(), keyword()) :: {:error, term()}
    def deliver(_email, _config), do: {:error, :smtp_unavailable}
  end

  setup do
    user = admin_user_fixture()
    assert_receive {:email, _setup_email}
    %{user: user, now: DateTime.utc_now(:second)}
  end

  test "JWT expiry schedules a reminder twelve hours before expiry with no token in job args", %{
    user: user,
    now: now
  } do
    expiry = DateTime.add(now, 7, :day)
    token = campfire_token_fixture(expiry)

    assert {:ok, saved_user} =
             Accounts.update_user_campfire_token(user, %{
               "campfire_token_input" => "Authorization: Bearer " <> token
             })

    assert saved_user.campfire_token_expires_at == expiry
    assert saved_user.campfire_token_reminded_at == nil
    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)
    assert DateTime.compare(job.scheduled_at, DateTime.add(expiry, -12, :hour)) == :eq

    assert job.args == %{
             "user_id" => user.id,
             "credential_version" => saved_user.encrypted_credentials["iv"]
           }

    refute Jason.encode!(job.args) =~ token
    refute_receive {:email, _}
  end

  test "uses the JWT's actual expiry instead of a manually supplied date", %{user: user, now: now} do
    expiry = DateTime.add(now, 7, :day)

    assert {:ok, saved_user} =
             Accounts.update_user_campfire_token(user, %{
               "campfire_token_input" => campfire_token_fixture(expiry),
               "campfire_token_expires_at" => DateTime.add(now, 30, :day)
             })

    assert saved_user.campfire_token_expires_at == expiry
  end

  test "supports a manually entered UTC expiry for opaque tokens", %{user: user, now: now} do
    expiry = now |> DateTime.add(7, :day) |> Map.put(:second, 0)
    local_input = Calendar.strftime(expiry, "%Y-%m-%dT%H:%M")

    assert {:ok, saved_user} =
             Accounts.update_user_campfire_token(user, %{
               "campfire_token_input" => "opaque-token",
               "campfire_token_expires_at" => local_input
             })

    assert saved_user.campfire_token_expires_at == expiry

    assert_enqueued(
      worker: TokenExpiryReminderJob,
      scheduled_at: DateTime.add(expiry, -12, :hour)
    )
  end

  test "rejects expired tokens and invalid manual dates without changing the saved token", %{
    user: user,
    now: now
  } do
    for attrs <- [
          %{"campfire_token_input" => campfire_token_fixture(DateTime.add(now, -1, :second))},
          %{"campfire_token_input" => "opaque-token", "campfire_token_expires_at" => "invalid"},
          %{"campfire_token_input" => "opaque-token", "campfire_token_expires_at" => now}
        ] do
      assert {:error, changeset} = Accounts.update_user_campfire_token(user, attrs)
      assert errors_on(changeset).campfire_token_expires_at
    end

    refute Accounts.get_user!(user.id).encrypted_credentials
    refute_enqueued(worker: TokenExpiryReminderJob)
  end

  test "unknown expiry remains supported without scheduling a speculative reminder", %{user: user} do
    assert {:ok, saved_user} =
             Accounts.update_user_campfire_token(user, %{"campfire_token_input" => "opaque-token"})

    assert saved_user.campfire_token_expires_at == nil
    refute_enqueued(worker: TokenExpiryReminderJob)

    for token <- [
          "opaque-token",
          "a.b.c",
          "a.#{Base.url_encode64("[]", padding: false)}.c",
          "a.#{Base.url_encode64(~s({"exp":"bad"}), padding: false)}.c",
          "a.#{Base.url_encode64(~s({"exp":99999999999999999999}), padding: false)}.c"
        ] do
      assert {:ok, credentials} = CampfireCredentials.normalize(token)
      assert CampfireCredentials.token_expiry(credentials) == nil
    end
  end

  test "queues immediately inside the twelve-hour window, emails the current admin address, and skips duplicates",
       %{
         user: user,
         now: now
       } do
    expiry = DateTime.add(now, 6, :hour)
    token = campfire_token_fixture(expiry)

    {:ok, saved_user} =
      Accounts.update_user_campfire_token(user, %{"campfire_token_input" => token})

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)
    assert abs(DateTime.diff(job.scheduled_at, now)) <= 2
    refute_receive {:email, _}

    email_address = "updated-admin@example.com"
    Repo.update!(change(saved_user, email: email_address))

    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    assert_receive {:email, email}
    assert email.to == [{"", email_address}]
    assert email.subject == "Your shared Campfire token is expiring"
    assert email.text_body =~ "https://campfire.scopely.com"
    assert email.text_body =~ CAToolsWeb.Endpoint.url() <> "/auth/users/settings"
    assert email.text_body =~ Calendar.strftime(expiry, "%Y-%m-%d %H:%M:%S UTC")
    assert email.text_body =~ "Logging in to Campfire alone does not update"
    refute email.text_body =~ token
    assert Accounts.get_user!(user.id).campfire_token_reminded_at

    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    refute_receive {:email, _}
  end

  test "does not send early and snoozes until the reminder time", %{user: user, now: now} do
    {:ok, _user} =
      Accounts.update_user_campfire_token(user, %{
        "campfire_token_input" => campfire_token_fixture(DateTime.add(now, 7, :day))
      })

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)

    assert {:snooze, seconds} = perform_job(TokenExpiryReminderJob, job.args)
    assert seconds in (6 * 86_400 + 43_200 - 2)..(6 * 86_400 + 43_200)
    refute_receive {:email, _}
    refute Accounts.get_user!(user.id).campfire_token_reminded_at
  end

  test "replacement cancels the old reminder even when the new token has the same expiry", %{
    user: user,
    now: now
  } do
    token = campfire_token_fixture(DateTime.add(now, 6, :hour))
    {:ok, _user} = Accounts.update_user_campfire_token(user, %{"campfire_token_input" => token})
    assert [old_job] = all_enqueued(worker: TokenExpiryReminderJob)

    {:ok, _user} = Accounts.update_user_campfire_token(user, %{"campfire_token_input" => token})
    assert Repo.get!(Oban.Job, old_job.id).state == "cancelled"
    assert [new_job] = all_enqueued(worker: TokenExpiryReminderJob)
    refute old_job.args == new_job.args

    assert :ok = perform_job(TokenExpiryReminderJob, old_job.args)
    refute_receive {:email, _}
    assert :ok = perform_job(TokenExpiryReminderJob, new_job.args)
    assert_receive {:email, _}
  end

  test "deleting a token clears expiry and prevents a reminder already picked up by a worker", %{
    user: user,
    now: now
  } do
    {:ok, _user} =
      Accounts.update_user_campfire_token(user, %{
        "campfire_token_input" => campfire_token_fixture(DateTime.add(now, 6, :hour))
      })

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)

    assert {:ok, saved_user} = Accounts.delete_user_campfire_token(user)
    assert saved_user.campfire_token_expires_at == nil
    assert saved_user.campfire_token_reminded_at == nil
    assert Repo.get!(Oban.Job, job.id).state == "cancelled"
    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    refute_receive {:email, _}
  end

  test "skips reminders after the administrator account is demoted or deleted", %{
    user: user,
    now: now
  } do
    {:ok, saved_user} =
      Accounts.update_user_campfire_token(user, %{
        "campfire_token_input" => campfire_token_fixture(DateTime.add(now, 6, :hour))
      })

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)

    Repo.update!(change(saved_user, admin: false))
    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    refute_receive {:email, _}

    Repo.delete!(Repo.get!(User, user.id))
    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    refute_receive {:email, _}
  end

  test "failed delivery remains retryable and is marked sent only after success", %{
    user: user,
    now: now
  } do
    {:ok, _user} =
      Accounts.update_user_campfire_token(user, %{
        "campfire_token_input" => campfire_token_fixture(DateTime.add(now, 6, :hour))
      })

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)
    previous = Application.fetch_env!(:ca_tools, CATools.Mailer)
    on_exit(fn -> Application.put_env(:ca_tools, CATools.Mailer, previous) end)

    Application.put_env(:ca_tools, CATools.Mailer, adapter: FailedMailer)
    assert {:error, :smtp_unavailable} = perform_job(TokenExpiryReminderJob, job.args)
    refute Accounts.get_user!(user.id).campfire_token_reminded_at

    Application.put_env(:ca_tools, CATools.Mailer, previous)
    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    assert_receive {:email, _}
    assert Accounts.get_user!(user.id).campfire_token_reminded_at
  end

  test "an overdue job still reminds the administrator after downtime", %{user: user, now: now} do
    {:ok, saved_user} =
      Accounts.update_user_campfire_token(user, %{
        "campfire_token_input" => campfire_token_fixture(DateTime.add(now, 6, :hour))
      })

    assert [job] = all_enqueued(worker: TokenExpiryReminderJob)
    Repo.update!(change(saved_user, campfire_token_expires_at: DateTime.add(now, -1, :hour)))

    assert :ok = perform_job(TokenExpiryReminderJob, job.args)
    assert_receive {:email, _}
  end
end
