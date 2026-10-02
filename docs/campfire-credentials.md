# Campfire credentials

The app uses your Campfire token to fetch meetups your account can access.

## Save a token

1. Open **Settings**.
2. Paste your token into **Campfire token or Authorization header**.
3. Select **Save Token**.

Accepted formats are a raw token, an `Authorization: Bearer ...` header, or
headers JSON containing the authorization header.

**Check token format** checks the input format. Campfire authentication is
checked when an import runs.

## Replace or delete a token

Paste a new token and save it to replace the existing one. If imports failed
because the previous token expired, open the map and select **Retry failed links**.

Select **Delete Saved Token** to remove it. Imports need a saved token to fetch
meetups.

## What is stored

The saved token is encrypted and used on the server. It is never displayed
again or included in public maps or exports.

See [troubleshooting](troubleshooting.md) if Campfire rejects an import.
