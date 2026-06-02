defmodule CAToolsWeb.Auth.UserSessionHTML do
  use CAToolsWeb, :html

  embed_templates "user_session_html/*"

  defp local_mail_adapter? do
    Application.get_env(:ca_tools, CATools.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
