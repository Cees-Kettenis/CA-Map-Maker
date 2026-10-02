# Deployment

Set these before starting a production release:

```text
DATABASE_URL=ecto://user:password@host/ca_tools_prod
SECRET_KEY_BASE=<generated application secret>
CREDENTIALS_MASTER_KEY_BASE64=<base64-encoded 32-byte key>
PHX_HOST=maps.example.com
PHX_SERVER=true
RESEND_API_KEY=<mail service key>
MAIL_FROM=maps@your-verified-domain.example
```

Use TLS at the reverse proxy and preserve `X-Forwarded-Proto`. Production cookies are secure and sensitive account changes require recent authentication. The database and encryption key need backups. Keep the same encryption key across restarts; changing it makes previously saved Campfire tokens unreadable. Development/test retain the existing local key for compatibility.

Generate a key once and store it securely with your deployment secrets:

```sh
openssl rand -base64 32
```

Optional settings:

- `PORT`, default `5000`.
- `CAMPFIRE_GRAPHQL_ENDPOINT`, default `https://niantic-social-api.nianticlabs.com/graphql`.
- `MAP_TILE_URL`, default `https://tile.openstreetmap.org/{z}/{x}/{y}.png`.
- `OBAN_IMPORT_QUEUE_LIMIT`, default `10`.
- `OBAN_MAINTENANCE_QUEUE_LIMIT`, default `2`.

Build assets with `MIX_ENV=prod mise exec -- mix assets.deploy`, build the release, then apply database migrations before serving traffic. Resend is the configured production mail adapter; it can be replaced with another Swoosh adapter if your deployment uses a different mail provider.

Leaflet is included locally under `priv/static/vendor/leaflet`. OpenStreetMap attribution remains visible. Follow the [tile usage policy](https://operations.osmfoundation.org/policies/tiles/) and switch to an appropriate tile provider for traffic beyond the shared service's capacity. Map rendering and tile configuration are separate from Campfire fetching.

Campfire is not a versioned public API. The query is intentionally small and follows the local campfire-tools reference. A token-backed import is the final verification of the current upstream schema and access permissions.
