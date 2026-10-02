defmodule CATools.Accounts.UserNotifier do
  import Swoosh.Email

  alias CATools.Mailer
  alias CATools.Accounts.User

  # Delivers the email using the application mailer.
  defp deliver(recipient, subject, body) do
    email =
      new()
      |> to(recipient)
      |> from(
        {"Campfire Atlas", Application.get_env(:ca_tools, :mail_from, "contact@example.com")}
      )
      |> subject(subject)
      |> text_body(body)

    with {:ok, _metadata} <- Mailer.deliver(email) do
      {:ok, email}
    end
  end

  @doc """
  Deliver instructions to update a user email.
  """
  @spec deliver_update_email_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_update_email_instructions(user, url) do
    deliver(user.email, "Update email instructions", """

    ==============================

    Hi #{user.email},

    You can change your email by visiting the URL below:

    #{url}

    If you didn't request this change, please ignore this.

    ==============================
    """)
  end

  @doc """
  Deliver instructions to log in with a magic link.
  """
  @spec deliver_login_instructions(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_login_instructions(user, url) do
    case user do
      %User{confirmed_at: nil} -> deliver_confirmation_instructions(user, url)
      _ -> deliver_magic_link_instructions(user, url)
    end
  end

  @doc "Sends the confirmation link for a password signup."
  @spec deliver_account_confirmation(User.t(), String.t()) ::
          {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_account_confirmation(user, url) do
    deliver(
      user.email,
      "Confirm your Campfire Atlas account",
      "Confirm your account by visiting:\n\n#{url}\n\nThis link expires in 24 hours."
    )
  end

  @doc "Sends a single-use password recovery link."
  @spec deliver_password_reset(User.t(), String.t()) :: {:ok, Swoosh.Email.t()} | {:error, term()}
  def deliver_password_reset(user, url) do
    deliver(
      user.email,
      "Reset your Campfire Atlas password",
      "Reset your password by visiting:\n\n#{url}\n\nThis link expires in one hour. Ignore it if you did not request a reset."
    )
  end

  defp deliver_magic_link_instructions(user, url) do
    deliver(user.email, "Log in instructions", """

    ==============================

    Hi #{user.email},

    You can log into your account by visiting the URL below:

    #{url}

    If you didn't request this email, please ignore this.

    ==============================
    """)
  end

  defp deliver_confirmation_instructions(user, url) do
    deliver(user.email, "Confirmation instructions", """

    ==============================

    Hi #{user.email},

    You can confirm your account by visiting the URL below:

    #{url}

    If you didn't create an account with us, please ignore this.

    ==============================
    """)
  end
end
