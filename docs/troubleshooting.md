# Troubleshooting

Check the error beside a source link in your owner map view.

| Problem | What to do |
| --- | --- |
| No saved Campfire token | [Save a token](campfire-credentials.md), then retry failed links |
| Campfire rejects the token | Replace it with a current token and retry |
| Meetup is unavailable | Open it in Campfire with the same account; confirm it still exists and is accessible |
| Missing or invalid coordinates | Check the meetup location in Campfire; retry after it is corrected |
| Unsupported link | Use a [meetup or event link](creating-maps.md#supported-links), rather than a club link |
| Duplicate event | Another link already imported that meetup; check the existing location |

## Links remain pending

The 50-link limit is shared across your maps. Remaining links wait for the next
10-minute scheduling window. Closing the page does not stop imports.

If links remain pending beyond the expected window, contact the operator of
your instance with the map name and the displayed status. You do not need to
send your Campfire token.

## A shared map will not open

Confirm that its visibility is **Public** and copy the share link again.
Private or deleted maps have no public view.

## Confirmation or recovery email is missing

Check your spam folder and the address you entered. Request a new recovery
link if the old one has expired. For a local development instance, emails
appear at `/dev/mailbox`.
