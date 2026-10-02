# Development

## Run locally

Install the versions in `.tool-versions` with mise. PostgreSQL must accept the development credentials in `config/dev.exs`, currently `postgres` / `postgres` on localhost.

```sh
mise install
mise exec -- mix setup
mise exec -- mix phx.server
```

Open http://localhost:5000. If another server uses that port, start with `PORT=5005 mise exec -- mix phx.server` instead. Restart an already running server after pulling these changes so migrations, runtime configuration and dependencies take effect.

For existing installations, run `mise exec -- mix ecto.migrate` before restarting. Maintenance attaches any old pending sources to import batches automatically.

Development emails appear at `/dev/mailbox`. Use it to follow confirmation and password recovery links.

## Checks

```sh
mise exec -- mix test
MIX_ENV=test mise exec -- mix dialyzer
mise exec -- mix format
mise exec -- mix assets.build
```

Tests cover authenticated event requests, public ID translation, parsing, failure handling, import jobs, batch limits, CRUD ownership, private/public access, KML, confirmation and recovery. They don't use a real Campfire token.

For a manual check with a real Campfire token, follow the [user guide](user-guide.md). Endpoint definitions are available at `/openapi.json`.
