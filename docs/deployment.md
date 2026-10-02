# Run with Docker

Docker Compose runs a production Elixir release and PostgreSQL, serving HTTP at `http://localhost:5000`. You do not need Elixir, Node or PostgreSQL installed on the host.

## Start

```sh
cp .env.docker.example .env.docker
```

Fill in `.env.docker`. Generate the three secrets separately:

```sh
openssl rand -hex 24                 # POSTGRES_PASSWORD
openssl rand -base64 64 | tr -d '\n' # SECRET_KEY_BASE
openssl rand -base64 32              # CREDENTIALS_MASTER_KEY_BASE64
```

Set the SMTP settings using your email provider. For Gmail:

1. Enable 2-Step Verification on the Google account you want to send from.
2. Create an [App Password](https://myaccount.google.com/apppasswords) for Campfire Atlas.
3. Set `SMTP_USERNAME` and `MAIL_FROM` to that Gmail address, and `SMTP_PASSWORD` to the App Password without spaces. Keep `SMTP_HOST=smtp.gmail.com`, `SMTP_PORT=587` and `SMTP_SECURITY=starttls`.

Use an App Password, not your regular Google password. Some managed accounts and Advanced Protection accounts do not offer App Passwords. See [Google's instructions](https://support.google.com/accounts/answer/185833).

Other providers can use their SMTP host and credentials. Both STARTTLS on port 587 and implicit TLS on port 465 are supported with certificate verification. For port 465, set `SMTP_SECURITY=ssl`. Your provider must allow password-based SMTP authentication and the sender address you choose. You do not need Resend or a separate email domain.

After starting the app, register an account and check that its confirmation email arrives. Test a password reset too. Development continues to use the local mailbox at `/dev/mailbox`.

Keep `PHX_HOST=localhost` and `APP_PORT=5000` for local use. Stop the local Phoenix server if it already uses port 5000. Then run:

```sh
docker compose --env-file .env.docker up -d --build --wait --remove-orphans
docker compose --env-file .env.docker logs -f app
```

Open `http://localhost:5000`. Email and sharing links use that same address. If you change `APP_PORT`, generated links include the new port. Previously sent emails keep their original URLs; request a new email after changing the address.

The application is bound to loopback on the host; PostgreSQL is not exposed. HTTPS and the Caddy proxy are disabled for now.

Database migrations run before the application starts. The application runs as an unprivileged user. The final Alpine image contains the compiled release and runtime libraries; build tools and source files stay in the build stage.

## Updates and persistence

```sh
docker compose --env-file .env.docker up -d --build --wait
```

Named volumes preserve PostgreSQL data, local meetup images across container replacements. Keep `.env.docker` and its encryption key across restarts. Back up the database, image files and deployment secrets together. `docker compose down` preserves volumes; `down -v` deletes them.

To back up the database:

```sh
docker compose --env-file .env.docker exec -T db pg_dump -U atlas -Fc ca_tools_prod > atlas.dump
```

## Bring your existing maps

The container starts with a separate database; it does not automatically move your development data.

1. Export the existing database with `pg_dump --format=custom` using its current connection settings.
2. Start the Docker database, restore the dump, then start the application:

```sh
docker compose --env-file .env.docker up -d db
docker compose --env-file .env.docker exec -T db pg_restore -U atlas -d ca_tools_prod --no-owner --no-acl < existing.dump
docker compose --env-file .env.docker up -d --build --wait
```

Restore into the empty Docker database before starting the app for the first time. If it already contains a new installation, use a fresh deployment database rather than merging the two.

Copy the existing image directory into the app's persistent volume, preserving permissions:

```sh
docker compose --env-file .env.docker cp storage/meetup_images/. app:/app/storage/meetup_images/
```

Keep the previous `CREDENTIALS_MASTER_KEY_BASE64` to decrypt existing saved Campfire tokens. If development used the default key and you choose a new production key, sign in and save the Campfire token again. Maps and images are unaffected by changing that key.

## Configuration

The runtime also supports `POOL_SIZE`, `CAMPFIRE_GRAPHQL_ENDPOINT`, `MAP_TILE_URL`, and the Oban queue limits. For a deployment with your own database or reverse proxy, run the same image with `DATABASE_URL`, `SECRET_KEY_BASE`, `CREDENTIALS_MASTER_KEY_BASE64`, `PHX_HOST`, `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `MAIL_FROM`, and mount a writable persistent directory at `/app/storage/meetup_images`. Set `PUBLIC_PORT` to the host HTTP port when running outside Compose.

Leaflet is bundled locally. OpenStreetMap remains the default tile provider; use an appropriate provider for your traffic and follow its [tile usage policy](https://operations.osmfoundation.org/policies/tiles/).
