# Run with Docker

Docker Compose runs a production Elixir release and PostgreSQL, serving HTTP at `http://localhost:5000`. You do not need Elixir, Node or PostgreSQL installed on the host.

## Publish the image with GitHub Actions

Create a public repository named `pogo-meetups` under your Docker Hub account. In this GitHub repository, open **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret | Value |
| --- | --- |
| `DOCKERHUB_USERNAME` | Your Docker Hub username, not your email address. |
| `DOCKERHUB_TOKEN` | A Docker Hub personal access token with Read & Write permission. |

The [publish workflow](../.github/workflows/docker-publish.yml) builds `linux/amd64` and `linux/arm64` images and publishes `YOUR_USERNAME/pogo-meetups:latest` on every push, including pushes to other branches and tags. A newer push cancels an older build. You can also run **Publish Docker image** manually from the Actions tab after configuring the secrets. See [Docker's multi-platform workflow documentation](https://docs.docker.com/build/ci/github-actions/multi-platform/).

Every CI build pulls the base images and upgrades Alpine packages in both the release builder and runtime stages. Cache reuse is disabled for those two stages so a cached layer cannot skip the upgrades. A separate `deps` stage caches compiled Elixir dependencies and downloaded asset tools in `YOUR_USERNAME/pogo-meetups:buildcache` on Docker Hub. Dependency files, compilation configuration, base image, or platform changes invalidate the matching dependency cache. The release builder copies dependency artifacts into its freshly updated environment; cached operating-system files are not copied into the final image. The first build fills this cache, while later UI changes can reuse the compiled dependencies. The existing Docker Hub secrets also authorize cache uploads.

Package upgrades use the configured Alpine release branch and the build fails if an upgrade fails. They do not guarantee that every reported vulnerability has an available fix. To refresh the entire dependency cache too, use a local full rebuild with `--no-cache`.

For a local image build with the same package refresh behavior, use:

```sh
docker buildx build --pull --no-cache-filter builder,runner --load -t pogo-meetups:local .
```

Wait for the workflow to finish successfully before pulling the image. Use a 64-bit operating system on the Raspberry Pi for the ARM64 image. Docker selects the matching architecture automatically. Builds run on GitHub; the Pi only pulls and runs the release.

## Start

The Pi needs Docker with Compose, this `compose.yaml`, the `docker/postgres` initialization files, and a populated `.env.docker`. The application source and build tools are not needed.

```sh
cp .env.docker.example .env.docker
```

Fill in `.env.docker`, including `DOCKERHUB_USERNAME` with the same username configured in GitHub. Keep the existing values when updating a deployment. Generate the three application secrets separately for a new installation:

```sh
openssl rand -hex 24                 # POSTGRES_PASSWORD
openssl rand -hex 24                 # POSTGRES_ADMIN_PASSWORD, different from the app password
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

SMTP credentials must already be configured in `.env.docker`; production refuses to start without them. Set `PHX_HOST` to the Pi's address or hostname and `APP_PORT` to the port users can reach so email links open the correct site. For access over Tailscale, set `PHX_HOST=100.70.128.90` and `APP_PORT=5000`.

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
docker compose --env-file .env.docker up -d --pull always --no-build --wait --remove-orphans
docker compose --env-file .env.docker logs -f app
```

Open `http://localhost:5000`. Email and sharing links use that same address. If you change `APP_PORT`, generated links include the new port. Previously sent emails keep their original URLs; request a new email after changing the address.

Compose publishes the application's HTTP port on all host interfaces, including the host's Tailscale IP. PostgreSQL is not exposed. HTTPS is handled by an external reverse proxy when configured.

When Nginx serves HTTPS and forwards requests to the app on port 5000, set these values in `.env.docker`:

```dotenv
PHX_HOST=cameetup.curious-code.fyi
PUBLIC_SCHEME=https
PUBLIC_PORT=443
APP_PORT=5000
```

Recreate the app with `docker compose --env-file .env.docker up -d --no-build --wait app`. New email and sharing links use `https://cameetup.curious-code.fyi` without a port number. Request a new email after updating; existing emails retain their old links.

`PUBLIC_SCHEME=https` also enables the browser session cookie's `Secure` flag at runtime, including when Nginx connects to the app over HTTP. Keep `PUBLIC_SCHEME=http` for standalone HTTP deployments. Both HTTP sessions and LiveView use the same runtime settings.

Database migrations run before the application starts. The application runs as an unprivileged user. The final Alpine image contains the compiled release and runtime libraries; build tools and source files stay in the build stage.

## Updates and persistence

```sh
docker compose --env-file .env.docker pull app
docker compose --env-file .env.docker up -d --no-build --wait
```

After a successful GitHub build, these commands pull the new application image and recreate the containers. Named volumes preserve PostgreSQL data and local meetup images across container replacements. Keep `.env.docker` and its encryption key across restarts. Back up the database, image files and deployment secrets together. `docker compose down` preserves volumes; `down -v` deletes them.

To back up the database:

```sh
docker compose --env-file .env.docker exec -T db pg_dump -U atlas -Fc ca_tools_prod > pogo-meetups.dump
```

### Database maintenance and existing deployments

Compose uses PostgreSQL 17.11 and separate `atlas_admin` and `atlas` accounts. The administrator credential stays in the database container; the application receives only `POSTGRES_PASSWORD`. `atlas` owns `ca_tools_prod` so ordinary schema migrations and trusted extensions work, but cannot administer roles, create databases, replicate, or bypass row-level security. Logs for the app and database rotate at 10 MiB with three files retained per container.

The initialization script configures these roles only on a new database volume. Existing volumes must be backed up and configured once before changing database credentials or replacing the container. Changing `POSTGRES_USER` in Compose does not modify an initialized database. The Pi setup repository's `Pi/deploy-pogo.py` coordinates the encrypted backup, existing-role setup, PostgreSQL 17 patch update, and proxy integration. Do not delete a volume to trigger initialization.

PostgreSQL's original bootstrap role must remain a superuser. The Pi installer temporarily connects through a separate maintenance superuser, renames the original `atlas` bootstrap role to `atlas_admin`, and creates a new restricted `atlas` login with the unchanged app password. `docker/postgres/roles.sql.in` transfers the application's tables, sequences, types, functions, and schema ownership transactionally, without transferring other databases, tablespaces, system catalogs, or extension implementation objects. The temporary maintenance login is removed afterward. Never substitute the administrator password into the application's `DATABASE_URL`.

PostgreSQL 17 patch releases reuse the existing data directory. Review intervening release notes for maintenance requirements and verify a backup before upgrading. PostgreSQL 18 is stable and the driver supports modern PostgreSQL versions, but moving from 17 to 18 requires a separate major-version migration.

## Bring your existing maps

The container starts with a separate database; it does not automatically move your development data.

1. Export the existing database with `pg_dump --format=custom` using its current connection settings.
2. Start the Docker database, restore the dump, then start the application:

```sh
docker compose --env-file .env.docker up -d db
docker compose --env-file .env.docker exec -T db pg_restore -U atlas -d ca_tools_prod --no-owner --no-acl < existing.dump
docker compose --env-file .env.docker pull app
docker compose --env-file .env.docker up -d --no-build --wait
```

Restore into the empty Docker database before starting the app for the first time. If it already contains a new installation, use a fresh deployment database rather than merging the two.

Copy the existing image directory into the app's persistent volume, preserving permissions:

```sh
docker compose --env-file .env.docker cp storage/meetup_images/. app:/app/storage/meetup_images/
```

Keep the previous `CREDENTIALS_MASTER_KEY_BASE64` to decrypt existing saved Campfire tokens. If development used the default key and you choose a new production key, sign in and save the Campfire token again. Maps and images are unaffected by changing that key.

## Configuration

The runtime also supports `POOL_SIZE`, `CAMPFIRE_GRAPHQL_ENDPOINT`, `MAP_TILE_URL`, and the Oban queue limits. For a deployment with your own database or reverse proxy, run the same image with `DATABASE_URL`, `SECRET_KEY_BASE`, `CREDENTIALS_MASTER_KEY_BASE64`, `PHX_HOST`, `SMTP_HOST`, `SMTP_USERNAME`, `SMTP_PASSWORD`, and `MAIL_FROM`, and mount a writable persistent directory at `/app/storage/meetup_images`. Set `PUBLIC_SCHEME` and `PUBLIC_PORT` to the scheme and port users reach. These default to `http` and the app's HTTP port.

Leaflet is bundled locally. OpenStreetMap remains the default tile provider; use an appropriate provider for your traffic and follow its [tile usage policy](https://operations.osmfoundation.org/policies/tiles/).

### Image processing

Vix runs libvips inside the application through its Elixir API. No separate image service is required. Its bundled native binaries support ARM64 Linux, including Alpine. Image downloads and migration jobs use a single-worker Oban `images` queue. Images are upgraded in batches of 20 every five minutes. Previously resized remote images are downloaded once more to recover their original detail; uploads use the available local copy without enlargement. If an upgrade download fails, the existing image stays available and the upgrade is not retried automatically. Cleanup runs daily at 03:00 UTC and preserves images referenced by recent meetups, communities or maps. Unreferenced files have a one-day grace period to allow uploads to finish attaching to their maps.

The default Compose project name is `pogo-meetups`, and the application image is `YOUR_USERNAME/pogo-meetups:latest`. For an existing deployment created under the previous name, set `COMPOSE_PROJECT_NAME=campfire-atlas` in `.env.docker` before upgrading to keep using its database and image volumes.
