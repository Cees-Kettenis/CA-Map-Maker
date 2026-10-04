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
2. Create an [App Password](https://myaccount.google.com/apppasswords) for Pogo Meetups.
3. Set `SMTP_USERNAME` and `MAIL_FROM` to that Gmail address, and `SMTP_PASSWORD` to the App Password without spaces. Keep `SMTP_HOST=smtp.gmail.com`, `SMTP_PORT=587` and `SMTP_SECURITY=starttls`.

Use an App Password, not your regular Google password. Some managed accounts and Advanced Protection accounts do not offer App Passwords. See [Google's instructions](https://support.google.com/accounts/answer/185833).

Other providers can use their SMTP host and credentials. Both STARTTLS on port 587 and implicit TLS on port 465 are supported with certificate verification. For port 465, set `SMTP_SECURITY=ssl`. Your provider must allow password-based SMTP authentication and the sender address you choose. You do not need Resend or a separate email domain.

Public signup is disabled. On a fresh database, opening the site redirects to **Set up your administrator**. Enter your email, follow the single-use password setup link, and choose a password of at least 12 characters. The app remains on setup until the password is saved, then signs you in and opens Settings to configure the shared Campfire token.

SMTP credentials must already be configured in `.env.docker`; production refuses to start without them. Set `PHX_HOST` to the Pi's address or hostname and `APP_PORT` to the port users can reach so email links open the correct site. For access over Tailscale, set `PHX_HOST=100.70.128.90`, `APP_BIND_ADDRESS=100.70.128.90`, and `APP_PORT=5000`.

Failed email delivery rolls back account creation. A pending setup keeps the selected admin email and offers **Request a new link** if the original expires after one hour. Once any existing installation is ready, setup closes. Restoring your existing database preserves your accounts and passwords and skips first-run setup.

Only the administrator can manage the token and open Accounts. Creating a user sends a single-use, one-hour password setup link. No password is displayed or sent. Development captures email locally at `/dev/mailbox`; production delivers through SMTP.

For trusted command-line bootstrap or admin password recovery, the release also supports:

```sh
read -rs -p 'Admin password: ' ADMIN_PASSWORD
export ADMIN_PASSWORD
docker compose --env-file .env.docker exec -e ADMIN_PASSWORD app bin/ca_tools eval 'CATools.Release.bootstrap_admin()'
unset ADMIN_PASSWORD
```

The command defaults to `cees9000@gmail.com` and resets that account's password and login tokens if it already exists. Pass `ADMIN_EMAIL` to use another address. The database permits only one administrator. If all accounts are deleted, the first-run wizard becomes available again; if regular accounts remain after admin deletion, use this trusted command to restore an administrator.

Every user can delete their own account after recent authentication and typing their email. Deletion cascades owned maps, meetups, sources, import history, communities, selections, invitations, login tokens, and upload ownership. It cancels and removes associated jobs and deletes exclusive cached images and uploads. Another user's references retain shared files. Pending image jobs cannot recreate unreferenced files after deletion. Backups and copies already downloaded by browsers are outside the live application's deletion scope.

Keep `PHX_HOST=localhost` and `APP_PORT=5000` for local use. Stop the local Phoenix server if it already uses port 5000. Then run:

```sh
docker compose --env-file .env.docker up -d --build --wait --remove-orphans
docker compose --env-file .env.docker logs -f app
```

Open `http://localhost:5000`. Email and sharing links use that same address. If you change `APP_PORT`, generated links include the new port. Previously sent emails keep their original URLs; request a new email after changing the address.

The application binds to loopback by default. Set `APP_BIND_ADDRESS` to the host's Tailscale IP to allow access from your tailnet. PostgreSQL is not exposed. HTTPS and the Caddy proxy are disabled for now.

Database migrations run before the application starts. The application runs as an unprivileged user. The final Alpine image contains the compiled release and runtime libraries; build tools and source files stay in the build stage.

## Updates and persistence

```sh
docker compose --env-file .env.docker up -d --build --wait
```

Named volumes preserve PostgreSQL data, local meetup images across container replacements. Keep `.env.docker` and its encryption key across restarts. Back up the database, image files and deployment secrets together. `docker compose down` preserves volumes; `down -v` deletes them.

To back up the database:

```sh
docker compose --env-file .env.docker exec -T db pg_dump -U atlas -Fc ca_tools_prod > pogo-meetups.dump
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

### Image processing

Vix runs libvips inside the application through its Elixir API. No separate image service is required. Its bundled native binaries support ARM64 Linux, including Alpine. Image downloads and migration jobs use a single-worker Oban `images` queue. Images are upgraded in batches of 20 every five minutes. Previously resized remote images are downloaded once more to recover their original detail; uploads use the available local copy without enlargement. If an upgrade download fails, the existing image stays available and the upgrade is not retried automatically. Cleanup runs daily at 03:00 UTC and preserves images referenced by recent meetups, communities or maps. Unreferenced files have a one-day grace period to allow uploads to finish attaching to their maps.

The default Compose project and image names are `pogo-meetups`. For an existing deployment created under the previous name, set `COMPOSE_PROJECT_NAME=campfire-atlas` in `.env.docker` before upgrading to keep using its database and image volumes.
