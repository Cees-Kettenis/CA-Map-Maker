defmodule CATools.PasswordRecoveryTest do
  use CATools.DataCase, async: true
  alias CATools.Accounts
  import CATools.AccountsFixtures

  test "password signup hashes the password and requires a single-use confirmation" do
    password = "a long signup password"
    {:ok, user} = Accounts.register_user(%{email: unique_user_email(), password: password})
    assert Bcrypt.verify_pass(password, user.hashed_password)
    assert user.password == nil
    assert Accounts.get_user_by_email_and_password(user.email, password) == nil
    token = extract_user_token(fn url -> Accounts.deliver_signup_instructions(user, url, url) end)
    assert {:ok, confirmed} = Accounts.confirm_user(token)
    assert confirmed.confirmed_at != nil
    assert Accounts.get_user_by_email_and_password(user.email, password).id == user.id
    assert {:error, :invalid_token} = Accounts.confirm_user(token)
  end

  test "reset tokens expire, are single use and revoke sessions" do
    user = user_fixture() |> set_password()
    session = Accounts.generate_user_session_token(user)
    token = extract_user_token(&Accounts.deliver_password_reset_instructions(user, &1))
    assert Accounts.get_user_by_password_reset_token(token).id == user.id
    assert {:error, %Ecto.Changeset{}} = Accounts.reset_user_password(token, %{password: "short"})

    assert {:ok, {_user, _revoked}} =
             Accounts.reset_user_password(token, %{
               password: "a brand new password",
               password_confirmation: "a brand new password"
             })

    assert Accounts.get_user_by_session_token(session) == nil
    assert Accounts.get_user_by_password_reset_token(token) == nil

    assert {:error, :invalid_token} =
             Accounts.reset_user_password(token, %{password: "another long password"})

    expired = extract_user_token(&Accounts.deliver_password_reset_instructions(user, &1))

    {:ok, query} =
      CATools.Accounts.UserToken.verify_email_token_query(expired, "reset_password", 3600)

    {_user, record} = Repo.one(query)

    Repo.update!(
      Ecto.Changeset.change(record,
        inserted_at: DateTime.add(DateTime.utc_now(:second), -3601, :second)
      )
    )

    assert Accounts.get_user_by_password_reset_token(expired) == nil
    assert Accounts.get_user_by_password_reset_token("invalid") == nil
  end
end
