# Import management

Open a map to see its source links, batch progress, and imported locations.
Imports continue while the browser is closed.

## Progress

| Source status | Meaning |
| --- | --- |
| Pending | Waiting to be processed |
| Processing | The app is fetching the meetup |
| Fetched | The location was saved |
| Failed | The fetch or parsing failed; an error appears beside the link |
| Skipped | The source was skipped, such as a duplicate event or cancelled import |

Imports process up to 50 links every 10 minutes per account, shared across all
its maps. A submission of 51 links needs at least two scheduling windows.
Failed imports can retry automatically up to three attempts.

## Retry or refresh

| Action | Links queued |
| --- | --- |
| Retry failed links | Failed or skipped sources |
| Refresh stale links | Completed sources last fetched more than 24 hours ago, or never fetched |
| Refresh all links | All completed sources |

Refreshes use the same scheduling limit. Existing locations remain visible
while their sources are refreshed.

If your token expired, [replace it](campfire-credentials.md) before retrying.
See [troubleshooting](troubleshooting.md) for other failures.

## Cancel a batch

Select **Cancel batch** and confirm to stop remaining imports. Locations
already fetched stay on the map. Use **Retry failed links** to queue skipped
sources again when you are ready.

## Temporary development control

In development, **Force fetch now** starts the selected batch immediately and
bypasses the 10-minute wait. It only affects that batch and does not duplicate
running imports. This temporary control is disabled in production.
