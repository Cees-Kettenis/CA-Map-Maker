# Campfire credentials

The app uses one encrypted token from the administrator to fetch meetups and monitor groups that the shared Campfire account can access. Regular users cannot see, save, or delete this token. See [My Communities](my-community.md) to connect a group.

## Save a token

1. Sign in as the administrator and open **Settings**.
2. Paste your token into **Campfire token or Authorization header**.
3. Expiry is read automatically from the token when available. Otherwise, enter **Expiry date and time (UTC)** to enable reminders.
4. Select **Save Token**.

Accepted formats are a raw token, an `Authorization: Bearer ...` header, or
headers JSON containing the authorization header.

**Check token format** checks the input format. Campfire authentication is
checked when an import runs.

## Expiry reminders

Settings shows the saved expiry in your browser's time zone. One email reminder is
scheduled for 12 hours before expiry and sent to the administrator's current account
email address. Tokens saved with less than 12 hours remaining trigger a reminder
immediately. An overdue reminder is delivered when the application resumes running.
Production uses the existing SMTP configuration; development captures the email at
`/dev/mailbox`. Failed deliveries are retried by the background job.

The email links to Campfire and Settings. Sign in to Campfire, copy
`CapacitorStorage.sessionToken` from its local storage, and save the new token here.
Signing in to Campfire alone does not replace the token used by this application.
Replacing or deleting a token cancels its pending reminder. The email never includes
the token itself.

Tokens saved before expiry reminders were added need to be saved again. A token
without a readable or manually entered expiry remains usable, but has no reminder.

## Replace or delete a token

Paste a new token and save it to replace the existing one. If imports failed
because the previous token expired, open the map and select **Retry failed links**.

Select **Delete Saved Token** to remove it. Imports need a saved token to fetch
meetups.

## What is stored

The saved token is encrypted and used on the server. It is never displayed
again or included in public maps or exports.

See [troubleshooting](troubleshooting.md) if Campfire rejects an import.
