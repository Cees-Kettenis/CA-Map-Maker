<p align="center">
  <img src="docs/assets/readme-banner.svg" alt="Pogo Meetups" />
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT license" /></a>
  <a href="docs/README.md"><img src="https://img.shields.io/badge/docs-user_guide-5263e5.svg" alt="User guide" /></a>
  <img src="https://img.shields.io/badge/elixir-~%3E%201.20-4B275F.svg" alt="Elixir ~> 1.20" />
</p>

# Pogo Meetups

Pogo Meetups turns Campfire meetup links into community maps. Import the
meetups you want to include, share a public map, or export KML for Google My Maps.

## What it does

1. [Map creation](docs/creating-maps.md): imports meetup locations, names, groups, and times using shared Campfire access configured by the administrator.
2. [Sharing](docs/sharing-maps.md): publishes a map through a public link, with private maps visible only to their owner.
3. [KML exports](docs/kml-exports.md): downloads locations for manual import into Google My Maps.
4. [My Communities](docs/my-community.md): monitors your groups and builds date-based meetup maps, with public read-only links or private access for invited accounts.
5. [Map updates](docs/imports.md): fetches new meetups, updates them daily, and supports immediate refreshes.

See the [user guide](docs/README.md) for account setup, Campfire tokens, and task guides.

Run in production with [Docker Compose](docs/deployment.md).

## Run locally

With mise and PostgreSQL installed:

```sh
mise install
mise exec -- mix setup
mise exec -- mix phx.server
```

Open http://localhost:5000. See [development](docs/development.md) for database
setup and checks, or [deployment](docs/deployment.md) to run your own instance.

## License

The application is [MIT licensed](LICENSE). Bundled Leaflet retains its
[BSD 2-Clause license](priv/static/vendor/leaflet/LICENSE).
