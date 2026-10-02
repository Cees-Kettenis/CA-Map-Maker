# Implementation status

The abandoned project had authentication, encrypted token storage, map creation, source/point tables, a dashboard shell, and a standalone importer. Its GraphQL query did not match campfire-tools, and creating a map never queued an import.

All six milestones in [the original plan](implementation-plan.md) now have implementations.

| Milestone | Implementation |
| --- | --- |
| Foundation | Phoenix LiveView, bcrypt passwords or email sign-in, email confirmation, account settings, AES-256-GCM credentials |
| Map CRUD | Owner-scoped creation, editing, deletion, visibility changes, public slugs |
| Campfire import | Req requests, bounded short-link redirects, public meetup ID translation, authenticated event query, normalized coordinates/times, duplicate-event handling |
| Oban pipeline | Import batches, scheduler, persistent per-user scheduling windows, 50 links per 600 seconds across maps, retries, cancellation, progress, recovery of legacy sources |
| Public map and KML | Leaflet/OpenStreetMap rendering, share links, public-safe JSON, public and private KML exports |
| Security and tests | Rate limits, 10,000-link cap, 2 MB body limit, scoped access, SSRF checks, escaped popups/XML, redacted credentials, production key/mail requirements, secure cookies, tested recovery tokens |

## Decisions resolved

- Leaflet 1.9.4 and its license are included locally. OpenStreetMap is the default tile provider. `MAP_TILE_URL` can change the provider. The map component and JavaScript hook isolate rendering from importing. Owner and public pages update as imports finish; an open public page redirects away when its map becomes private.
- Original/resolved Campfire source links appear only in owner views and owner KML. Public maps and public KML omit them.
- Raw Campfire responses are not stored. Only normalized fields and their SHA-256 hash are persisted.
- Imports accept at most 10,000 unique source URLs. There is no lifetime map count limit. Creation requests are rate limited.
- Token saving validates its format. Live Campfire authentication is checked during import. The UI states this explicitly and permits replacing an expired token.
- Signup accepts a bcrypt password or email-only sign-in. Password accounts require confirmation before login and support one-hour, single-use recovery links. Resetting a password revokes sessions.
- Refresh is owner-initiated for failed, stale, or all links. Stale means older than 24 hours. Every refresh uses the same per-user scheduler window.
- A minute-based maintenance job schedules legacy/pending sources. Oban Lifeline recovers stuck jobs, and Pruner removes old job records.
- Public export is `/maps/:slug/export.kml`. The original `.kml` suffix route was an example; this route works with current Plug routing and Phoenix verified routes.

## GraphQL comparison

The implementation uses a map-specific subset of the same Event fields used by campfire-tools' club feeds and Event query:

- Endpoint: `https://niantic-social-api.nianticlabs.com/graphql`.
- Root: `event(id: $id)`.
- Fields: `id`, `name`, `details`, `eventTime`, `eventEndTime`, `address`, scalar `location`, and `club { id name }`.
- Location strings contain longitude first, then latitude. JSON arrays and comma-separated strings are accepted, as in the reference parser. Invalid/out-of-range coordinates fail the source.
- Direct discover links already contain the event ID. Short links need redirect resolution.
- `niantic-social.nianticlabs.com/public/meetup/:id` contains a public map object ID. `publicMapObjectsById` on `/public/graphql` translates it to the event ID before the authenticated request.

This app imports meetup/event links. Importing every event in a club feed is outside the supplied implementation plan.

## Dependency warning fixes

Elixir 1.20 checks revealed a redundant error clause in the importer, which also hid changeset errors. That clause order is corrected.

DNSCluster and LiveView were updated. Three dependencies use fixed upstream Git commits until corresponding Hex releases include the fixes:

- [Gettext compiler/type fixes](https://github.com/elixir-gettext/gettext/commit/3163e3cbf6c015d9e37efa08adf42dc3e907f58b).
- [Phoenix Ecto xref configuration fix](https://github.com/phoenixframework/phoenix_ecto/commit/d0b02063159762791982c0d44beff411b61cc5f7).
- [LiveDashboard optional Postgrex warning fix](https://github.com/phoenixframework/phoenix_live_dashboard/commit/83a0bd137ed3e4c66b8037b140a2744803a48e13).

These pins are in mix.exs and mix.lock. Revisit them when updating dependencies.

## External verification

Validation completed with 190 passing tests, zero Dialyzer errors, formatting checks, and an asset build. Browser checks used sample meetups in a separate preview database, on desktop and mobile. The 10,000-link test verifies persistence and the 50-job scheduling limit without contacting Campfire.

Automated API tests use realistic mocked Campfire responses. A real import requires a currently valid token and an accessible meetup. Follow the [user guide](user-guide.md) for that manual check.

Production needs your database, encryption key, host, application secret, and verified mail sender. Deployment itself is not part of this implementation.
