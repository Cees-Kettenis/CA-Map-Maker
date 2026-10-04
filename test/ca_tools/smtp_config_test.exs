defmodule CATools.SMTPConfigTest do
  use ExUnit.Case, async: false

  @runtime_env ~w(SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USERNAME SMTP_PASSWORD MAIL_FROM PHX_HOST PUBLIC_SCHEME PUBLIC_PORT PORT DATABASE_URL SECRET_KEY_BASE CREDENTIALS_MASTER_KEY_BASE64)

  setup do
    previous = Map.new(@runtime_env, &{&1, System.get_env(&1)})

    System.put_env(%{
      "SMTP_HOST" => "smtp.example.com",
      "SMTP_USERNAME" => "atlas@example.com",
      "SMTP_PASSWORD" => "test-app-password",
      "MAIL_FROM" => "atlas@example.com",
      "DATABASE_URL" => "ecto://postgres:postgres@localhost/ca_tools_test",
      "SECRET_KEY_BASE" => String.duplicate("x", 64),
      "CREDENTIALS_MASTER_KEY_BASE64" => Base.encode64(:binary.copy(<<0>>, 32))
    })

    Enum.each(~w(PHX_HOST PUBLIC_SCHEME PUBLIC_PORT PORT), &System.delete_env/1)
    System.delete_env("SMTP_PORT")
    System.delete_env("SMTP_SECURITY")

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)

    :ok
  end

  test "production requires authenticated STARTTLS and verifies the SMTP server" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    mailer = config[:ca_tools][CATools.Mailer]

    assert mailer[:adapter] == Swoosh.Adapters.SMTP
    assert mailer[:relay] == "smtp.example.com"
    assert mailer[:username] == "atlas@example.com"
    assert mailer[:password] == "test-app-password"
    assert mailer[:port] == 587
    assert mailer[:ssl] == false
    assert mailer[:tls] == :always
    assert mailer[:auth] == :always
    assert mailer[:no_mx_lookups] == true
    assert mailer[:tls_options][:verify] == :verify_peer
    assert mailer[:tls_options][:server_name_indication] == ~c"smtp.example.com"
    assert [_ | _] = mailer[:tls_options][:cacerts]
    assert config[:ca_tools][:mail_from] == "atlas@example.com"
  end

  test "implicit TLS defaults to 465 and applies verification to the initial socket" do
    System.put_env("SMTP_SECURITY", "ssl")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    mailer = config[:ca_tools][CATools.Mailer]

    assert mailer[:port] == 465
    assert mailer[:ssl] == true
    assert mailer[:tls] == :never
    assert mailer[:sockopts][:verify] == :verify_peer
    assert mailer[:sockopts][:server_name_indication] == ~c"smtp.example.com"
  end

  test "rejects missing credentials, insecure modes and invalid ports" do
    System.put_env("SMTP_PASSWORD", "")

    assert_raise RuntimeError, "SMTP_PASSWORD is required in production", fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end

    System.put_env("SMTP_PASSWORD", "test-app-password")
    System.put_env("SMTP_SECURITY", "none")

    assert_raise RuntimeError, "SMTP_SECURITY must be starttls or ssl", fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end

    System.put_env("SMTP_SECURITY", "starttls")
    System.put_env("SMTP_PORT", "0")

    assert_raise RuntimeError, "SMTP_PORT must be between 1 and 65535", fn ->
      Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    end
  end

  test "production rejects a short session secret before serving requests" do
    System.put_env("SECRET_KEY_BASE", "too-short")

    assert_raise RuntimeError,
                 "SECRET_KEY_BASE must be at least 64 bytes; generate it with mix phx.gen.secret",
                 fn ->
                   Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
                 end
  end

  test "generated links use HTTP and the published port" do
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)

    assert config[:ca_tools][CAToolsWeb.Endpoint][:url] == [
             host: "localhost",
             port: 5000,
             scheme: "http"
           ]

    System.put_env("PUBLIC_PORT", "5006")
    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    assert config[:ca_tools][CAToolsWeb.Endpoint][:url][:port] == 5006
  end

  test "public HTTPS URL is independent of the internal HTTP port" do
    System.put_env(%{
      "PHX_HOST" => "cameetup.curious-code.fyi",
      "PUBLIC_SCHEME" => "https",
      "PUBLIC_PORT" => "443",
      "PORT" => "5000"
    })

    config = Config.Reader.read!("config/runtime.exs", env: :prod, target: :host)
    endpoint = config[:ca_tools][CAToolsWeb.Endpoint]

    assert endpoint[:http][:port] == 5000
    assert endpoint[:url] == [host: "cameetup.curious-code.fyi", port: 443, scheme: "https"]

    assert URI.to_string(struct!(URI, endpoint[:url])) == "https://cameetup.curious-code.fyi"
  end
end
