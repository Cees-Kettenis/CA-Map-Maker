# Campfire Map SaaS Implementation Plan

Historical design notes: public signup and per-user tokens below have been superseded by admin-created accounts and one shared admin token. See [account setup](accounts.md) and [deployment](deployment.md) for current behavior.

## 1. Product Summary

Build a Phoenix LiveView SaaS application where users can sign up, store their Campfire credentials securely, create maps from Niantic Campfire links, and share those maps publicly through the application.

The app will not attempt to create Google My Maps programmatically. Instead, it will provide:

1. An app-hosted public map page.
2. KML export as a fallback/manual import option for Google My Maps.
3. Optional Google Maps URL links for individual points only, not as the main multi-point sharing mechanism.

Google My Maps supports importing KML files manually, but there is no planned Google My Maps API integration for automatic public map creation.

## 2. Finalized Decisions

### 2.1 Map Sharing

Primary sharing method:

- App-hosted public map page.
- Route example: `/maps/:public_slug`.
- The map displays all fetched Campfire points with title, group name, coordinates, and optional metadata.

Backup sharing/export method:

- KML export.
- Route examples:
  - Public: `/maps/:public_slug.kml`
  - Private owner export: `/dashboard/maps/:id/export.kml`
- User can manually import the KML into Google My Maps.

No direct Google My Maps creation or publishing integration will be built.

### 2.2 Google Integration

No Google OAuth and no Google token storage for now.

If the app-hosted public map uses Google Maps JavaScript API later, use an app-level browser API key configured through environment variables.

For the current implementation plan, the map rendering should be abstracted so the app can use one of these:

- Leaflet + OpenStreetMap tiles; recommended if avoiding Google entirely.
- Google Maps JavaScript API with an app-level API key; optional later.

### 2.3 Campfire Credentials

Each user stores their own Campfire token in their profile.

The token should be treated like a password:

- Never logged.
- Never rendered back after saving.
- Never exposed in JSON responses.
- Only replaceable or deletable.
- Used only server-side for Campfire link fetches.

The credential form should allow the user to paste one of these formats:

- Raw bearer token.
- Full `Authorization: Bearer ...` header.
- Headers JSON, if needed later.

The app should normalize this input before encrypting and storing it.

### 2.4 Credential Storage

Sensitive credentials should be stored in one encrypted JSON field.

User table field:

```elixir
field :encrypted_credentials, :map
```

Plain JSON before encryption:

```json
{
  "campfire": {
    "token": "...",
    "token_type": "bearer"
  }
}
```

Encrypted DB value:

```json
{
  "v": 1,
  "alg": "AES-256-GCM",
  "iv": "base64...",
  "tag": "base64...",
  "ciphertext": "base64..."
}
```

Encryption requirements:

- AES-256-GCM.
- 256-bit master key from environment variable.
- Unique random 96-bit IV per encryption.
- Store auth tag separately.
- Use authenticated additional data such as `user_credentials:v1:<user_id>`.
- Any tampering must fail decryption.
- Key rotation should be possible later by adding `key_id`.

Environment example:

```bash
CREDENTIALS_MASTER_KEY_BASE64=...
```

### 2.5 Authentication

Use Phoenix authentication with bcrypt.

Dependencies:

```elixir
{:bcrypt_elixir, "~> 3.0"}
```

Authentication requirements:

- Sign up.
- Log in.
- Log out.
- Email confirmation.
- Password reset.
- Backend rate limiting.
- Failed-login throttling.
- Unique email enforced at database level.

### 2.6 Background Jobs

Use Oban, not Quantum.

Oban should be used for:

- Campfire link import jobs.
- Campfire link refresh jobs.
- Retry failed fetches.
- Processing large imports in batches.
- Optional periodic maintenance jobs.

Oban is backed by the app database and supports queues, scheduled jobs, retries, uniqueness, and cron-style periodic jobs.

### 2.7 HTTP Requests

Use `Req` for all outbound HTTP requests.

External request code must live in dedicated modules:

```elixir
MyApp.Campfire.LinkResolver
MyApp.Campfire.GraphQLClient
MyApp.Campfire.Importer
```

LiveViews should never call Campfire directly.

### 2.8 User Limits

No total limit on how many maps a user can create for now.

However, abuse controls must exist.

Large link imports are allowed, but processed slowly and safely.

If a user pastes 10,000 links, the app should:

- Accept the import if the request itself is within configured body size.
- Create source records in the database.
- Queue import jobs.
- Process at most 50 links every 10 minutes per user.
- Show progress in the UI.
- Avoid blocking the LiveView request.

This means "no map creation limit" does not mean "unlimited immediate processing."

## 3. Main User Flows

### 3.1 Signup Flow

1. User opens signup page.
2. User submits email and password.
3. Backend validates and rate-limits signup.
4. Password is hashed using bcrypt.
5. Confirmation email is sent.
6. User confirms email.
7. User can log in.

Server-side signup protections:

- Limit by IP.
- Limit by email.
- Debounce form events for UX only.
- Do not rely on debounce for security.
- Optional CAPTCHA can be added later if abuse starts.

### 3.2 Credential Setup Flow

1. User opens profile credentials page.
2. User pastes Campfire token or authorization header.
3. App normalizes token.
4. App optionally validates token with a small Campfire request.
5. App encrypts credentials JSON.
6. App stores encrypted value in `users.encrypted_credentials`.
7. UI shows only masked status, for example: `Campfire token saved`.

### 3.3 Create Map Flow

1. User clicks "New map".
2. User enters:
   - map name;
   - optional description;
   - visibility: private or public;
   - list of Campfire links, one per line.
3. App creates a `maps` record owned by the current user.
4. App creates one `map_sources` record per submitted link.
5. App queues Oban jobs for processing.
6. UI shows import progress.

### 3.4 Campfire Import Flow

For each source link:

1. Validate URL domain.
2. Resolve redirects with strict limits.
3. Extract Campfire meetup/event ID.
4. Decrypt user's Campfire token server-side.
5. Call Campfire GraphQL with `Req`.
6. Extract:
   - group name;
   - title;
   - latitude;
   - longitude;
   - address if present;
   - start/end time if present;
   - source URL;
   - Campfire ID.
7. Store normalized data in `map_points`.
8. Mark source as fetched or failed.

### 3.5 Dashboard Flow

User dashboard shows only maps owned by the current user.

Users can:

- create maps;
- view import progress;
- refresh failed/stale links;
- edit map name/description/visibility;
- delete maps;
- export KML;
- copy public share link if map is public.

### 3.6 Public Map Flow

If map visibility is public:

- Route: `/maps/:public_slug`.
- Displays map points without requiring login.
- Does not expose owner credentials.
- Does not expose private map metadata.
- Shows only public-safe fields.

If map is private:

- Public slug route returns 404.
- Owner can still view it in dashboard.

### 3.7 KML Export Flow

KML export should generate a valid KML document containing all map points.

KML placemark example:

```xml
<Placemark>
  <name>Community Day Meetup</name>
  <description><![CDATA[
    Group: Kuala Lumpur Pokémon GO<br/>
    Source: https://cmpf.re/example
  ]]></description>
  <Point>
    <coordinates>101.6869,3.1390,0</coordinates>
  </Point>
</Placemark>
```

Important:

- KML coordinates are `longitude,latitude,altitude`.
- Escape XML safely.
- Avoid leaking private/token-backed data.
- KML export should work for both small and large maps.

## 4. Data Model

### 4.1 users

```text
id
email
hashed_password
confirmed_at
encrypted_credentials
inserted_at
updated_at
```

### 4.2 maps

```text
id
user_id
name
description
visibility
public_slug
points_count
sources_count
last_imported_at
inserted_at
updated_at
```

Indexes:

```text
unique public_slug
index user_id
index user_id, inserted_at
```

### 4.3 map_sources

```text
id
map_id
original_url
resolved_url
campfire_id
status
error_code
error_message
attempts
last_fetched_at
next_fetch_at
inserted_at
updated_at
```

Statuses:

```text
pending
processing
fetched
failed
skipped
```

Indexes:

```text
index map_id
index status
index next_fetch_at
unique map_id, original_url
unique map_id, campfire_id where campfire_id is not null
```

### 4.4 map_points

```text
id
map_id
map_source_id
campfire_id
group_name
title
description
latitude
longitude
address
starts_at
ends_at
source_url
payload_hash
inserted_at
updated_at
```

Indexes:

```text
index map_id
index map_source_id
index campfire_id
index latitude, longitude
```

### 4.5 import_batches

Useful for large imports.

```text
id
user_id
map_id
status
total_count
processed_count
success_count
failed_count
inserted_at
updated_at
```

Statuses:

```text
queued
processing
completed
completed_with_errors
failed
cancelled
```

## 5. Oban Design

### 5.1 Queues

Recommended queues:

```elixir
queues: [
  campfire_import: 5,
  campfire_refresh: 2,
  maintenance: 1
]
```

### 5.2 Workers

```elixir
MyApp.Workers.CampfireImportWorker
MyApp.Workers.CampfireRefreshWorker
MyApp.Workers.ImportBatchSchedulerWorker
MyApp.Workers.CleanupWorker
```

### 5.3 Processing Limit: 50 Links Every 10 Minutes Per User

Do not enqueue 10,000 executable jobs all at once for one user.

Recommended design:

1. Store all submitted links as `map_sources` with `pending` status.
2. Create an `import_batches` record.
3. Schedule a batch scheduler job immediately.
4. Scheduler selects up to 50 pending sources for that user.
5. Scheduler enqueues import jobs for those 50 sources.
6. Scheduler schedules itself again in 10 minutes if more pending sources remain.

Pseudo-flow:

```elixir
pending_sources = Sources.next_pending_for_user(user_id, limit: 50)

Enum.each(pending_sources, fn source ->
  %{source_id: source.id}
  |> CampfireImportWorker.new(queue: :campfire_import)
  |> Oban.insert()
end)

if Sources.more_pending_for_user?(user_id) do
  %{user_id: user_id, batch_id: batch_id}
  |> ImportBatchSchedulerWorker.new(schedule_in: 600)
  |> Oban.insert()
end
```

Add uniqueness so duplicate scheduler jobs are not created for the same user/batch.

## 6. Campfire GraphQL Handling

The GraphQL endpoint and query should be configurable because Campfire is not a stable public API.

Config:

```elixir
config :my_app, MyApp.Campfire,
  graphql_endpoint: System.get_env("CAMPFIRE_GRAPHQL_ENDPOINT")
```

The importer should not assume one permanent query forever.

It should isolate parsing in a module:

```elixir
MyApp.Campfire.ResponseParser.extract_meetup(payload)
```

Expected normalized result:

```elixir
%{
  campfire_id: "...",
  group_name: "...",
  title: "...",
  latitude: 3.1390,
  longitude: 101.6869,
  address: "...",
  starts_at: ~U[...],
  ends_at: ~U[...]
}
```

If required fields are missing:

- Missing title: mark failed or use fallback from source.
- Missing group name: allow nil but warn.
- Missing coordinates: mark failed because it cannot be plotted.

## 7. Security Requirements

### 7.1 Authorization

Every private query must scope by `current_user.id`.

Bad:

```elixir
Repo.get!(Map, id)
```

Good:

```elixir
Repo.get_by!(Map, id: id, user_id: current_user.id)
```

Authorization must be enforced in context functions, not only LiveViews.

### 7.2 Token Security

- Treat Campfire token as password-equivalent.
- Never log request headers.
- Never inspect decrypted credential maps in logs.
- Redact token fields in errors.
- Do not return decrypted token to the browser.
- Do not put tokens in Oban args.

Oban job args should contain IDs only:

```elixir
%{"source_id" => source.id}
```

Worker loads source, map, user, then decrypts credentials inside the worker.

### 7.3 SSRF Protection

When resolving Campfire links:

- Allow only `cmpf.re` and `campfire.nianticlabs.com`.
- Limit redirects.
- Timeout requests.
- Reject redirects to private IP ranges.
- Reject non-HTTP/HTTPS schemes.
- Reject URLs with embedded credentials.

### 7.4 Public Data Safety

Public map JSON must not include:

- user email;
- encrypted credentials;
- raw Campfire payload;
- internal error messages;
- private source metadata;
- Oban job IDs.

### 7.5 KML Safety

- Escape XML fields.
- Use CDATA carefully.
- Sanitize strings before embedding in descriptions.
- Do not include secrets or raw payloads.

### 7.6 Backend Rate Limits

Required limits:

- Signup attempts by IP/email.
- Failed login attempts by IP/email.
- Credential validation attempts by user/IP.
- Map creation attempts by user/IP.
- Import scheduling: 50 links every 10 minutes per user.
- Request body size limit for huge link submissions.

## 8. Suggested Dependencies

```elixir
defp deps do
  [
    {:phoenix, "~> 1.7"},
    {:phoenix_live_view, "~> 1.0"},
    {:ecto_sql, "~> 3.12"},
    {:postgrex, ">= 0.0.0"},
    {:bcrypt_elixir, "~> 3.0"},
    {:req, "~> 0.5"},
    {:oban, "~> 2.20"},
    {:jason, "~> 1.4"},
    {:sweet_xml, "~> 0.7"}
  ]
end
```

Note: exact versions should be checked when implementation starts.

## 9. Testing Plan

### 9.1 Auth Tests

- User can sign up.
- Duplicate email rejected.
- Password is hashed with bcrypt.
- Login succeeds with valid credentials.
- Login fails with invalid credentials.
- Failed login throttling works.
- Email confirmation works.
- Password reset works.

### 9.2 Credential Tests

- Credentials are encrypted before storage.
- DB value does not contain plaintext token.
- Decryption returns original token.
- IV changes every save.
- Tampered ciphertext fails.
- Tampered auth tag fails.
- Wrong master key fails.
- Token is not rendered in profile HTML.
- Token is not present in logs.

### 9.3 Campfire Link Tests

Use request mocks or `Req.Test`.

- Resolves valid `cmpf.re` link.
- Rejects unsupported domain.
- Rejects too many redirects.
- Rejects redirect to private IP.
- Extracts Campfire meetup/event ID.
- Handles GraphQL success.
- Handles GraphQL auth failure.
- Handles missing group name.
- Handles missing title.
- Fails when coordinates are missing.
- Stores fetch error safely.

### 9.4 Import Batch Tests

- Large import creates source records.
- Only 50 links are scheduled in the first 10-minute window.
- Remaining links stay pending.
- Scheduler schedules another batch after 10 minutes.
- Duplicate scheduler jobs are prevented.
- Cancelled batch stops future scheduling.
- Import progress counters update correctly.

### 9.5 Authorization Tests

- User sees only own maps.
- User cannot view another user's private map.
- User cannot edit another user's map.
- User cannot delete another user's map.
- Public map can be viewed without login.
- Private map public slug returns 404.

### 9.6 Public Map Tests

- Public endpoint returns only public-safe fields.
- Public endpoint does not expose user email.
- Public endpoint does not expose credentials.
- Marker data includes title, group name, latitude, longitude.
- Invalid slug returns 404.

### 9.7 KML Tests

- KML response has correct content type.
- KML has valid XML structure.
- Coordinates are longitude,latitude,altitude.
- Empty map returns valid KML.
- Special characters are escaped.
- Secrets are not included.
- Large maps can export successfully.

### 9.8 Security Tests

- CSRF protection remains enabled.
- Secure cookie settings are correct in production config.
- Rate limits are enforced server-side.
- Logs redact sensitive fields.
- Oban args do not contain tokens.
- Public routes never leak private data.

## 10. Open Questions Before Implementation

These should be answered before coding starts.

### 10.1 Map Renderer

Do you want the app-hosted public map to use:

1. Leaflet + OpenStreetMap tiles, no Google dependency.
2. Google Maps JavaScript API, app-level API key.

Current recommendation: Leaflet first, because you said no Google integration is needed and KML export covers the Google/My Maps fallback.

### 10.2 Public Source Links

Should public map marker popups include the original Campfire link?

Options:

1. Show original Campfire link publicly.
2. Show only title/group/coordinates/time.
3. Show Campfire link only to the owner.

Current recommendation: show source links only to the owner unless you explicitly want public Campfire links shared.

### 10.3 Raw Payload Storage

Should the app store raw Campfire GraphQL payloads?

Options:

1. Do not store raw payloads.
2. Store sanitized JSON.
3. Store encrypted raw payloads.

Current recommendation: do not store raw payloads for v1. Store normalized fields plus `payload_hash`.

### 10.4 Import Size Hard Cap

Should there be a maximum number of links per submitted import?

Even with 50 per 10 minutes processing, a request containing millions of links must be rejected.

Current recommendation:

- Accept up to 10,000 links per import batch for now.
- Process 50 every 10 minutes per user.
- Add an admin-configurable max later.

### 10.5 Campfire Token Validation

Should the app require token validation before saving?

Options:

1. Save token immediately, validate during import.
2. Validate token first, only save if valid.

Current recommendation: validate first if possible, but allow save with warning if Campfire validation endpoint/query is temporarily failing.

## 11. Milestone Plan

### Milestone 1: Foundation

- Phoenix LiveView app.
- Auth with bcrypt.
- User profile.
- Encrypted credentials field.
- Basic dashboard shell.

### Milestone 2: Map CRUD

- Create/edit/delete maps.
- Private/public visibility.
- Ownership enforcement.
- Public slug generation.

### Milestone 3: Campfire Import

- Link resolver.
- GraphQL client using Req.
- Response parser.
- Source and point storage.
- Manual import for small batches.

### Milestone 4: Oban Import Pipeline

- Oban setup.
- Import workers.
- Batch scheduler.
- 50 links every 10 minutes per user.
- Progress UI.

### Milestone 5: Public Map + KML

- Public app-hosted map route.
- Public-safe points endpoint.
- KML export.
- Owner-only/private export route.

### Milestone 6: Security + Tests

- Rate limits.
- SSRF protections.
- Log redaction.
- Full test suite.
- Production config review.

## 12. Final Direction

Build a Phoenix LiveView SaaS app with bcrypt authentication, encrypted user credential JSON, Req-based Campfire GraphQL importing, Oban-based background processing, app-hosted public maps, and KML export.

Do not build Google My Maps automation. KML export is the manual bridge to Google My Maps.

Large imports should be accepted into the database but processed at a controlled backend rate of 50 links every 10 minutes per user.
